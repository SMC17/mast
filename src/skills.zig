// skills.zig — skill loader for mast's agentic loop.
//
// A skill is a *.janet file under ~/.config/mast/skills/ (or subdirs)
// with a comment-header frontmatter block at the top:
//
//   # name: type1-audit
//   # version: 0.1.0
//   # category: verification
//   # description: Run the Type-I overclaim audit pipeline
//   # requires: exec
//
// The file must define a (run ...) function. mast loads the source, evals
// it to define (run ...), then calls (run arg1 arg2 ...) on invocation.
//
// Security: skills that declare `requires: exec` (or another capability)
// are only invocable when the sandbox has that capability. This piggybacks
// the existing capability model at zero extra cost.
//
// Lifecycle: Skills loaded at startup via loadSkills(). A Janet-level
// (skill/reload) rescans the directory at runtime.
//
// File I/O: libc-only, consistent with audit.zig + zk.zig — insulates from
// std.fs/std.Io churn across Zig 0.13–0.16.

const std = @import("std");
const sandbox = @import("sandbox.zig");

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("errno.h");
});

pub const Capability = sandbox.Capability;

pub const Skill = struct {
    name: []const u8,
    version: []const u8,
    category: []const u8,
    description: []const u8,
    required_cap: ?Capability,
    // Full Janet source including the (run ...) definition.
    source: []const u8,
    // Absolute path — kept for reload and for audit events.
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Skill) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.category);
        self.allocator.free(self.description);
        self.allocator.free(self.source);
        self.allocator.free(self.path);
    }
};

pub const Skills = struct {
    items: []Skill,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Skills) void {
        for (self.items) |*s| s.deinit();
        self.allocator.free(self.items);
        self.allocator.destroy(self);
    }

    /// Find a skill by name. O(n) — skill counts are small (<100).
    pub fn find(self: *const Skills, name: []const u8) ?*const Skill {
        for (self.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

pub const Error = error{
    OpenFailed,
    ReadFailed,
    OutOfMemory,
    MissingName,
};

/// Load all skills from the skills directory. If the directory does not
/// exist, returns an empty Skills (zero items, no error). Callers should
/// call deinit() on the returned pointer when done.
pub fn loadSkills(allocator: std.mem.Allocator) !*Skills {
    var dir_path_buf: [512]u8 = undefined;
    const dir_path = resolveSkillsDir(&dir_path_buf);

    var list: std.ArrayList(Skill) = .empty;
    errdefer {
        for (list.items) |*s| s.deinit();
        list.deinit(allocator);
    }

    if (dir_path) |dp| {
        scanDir(allocator, dp, &list) catch {};
    }

    const result = try allocator.create(Skills);
    result.* = .{
        .items = try list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    return result;
}

/// Resolve the skills directory into buf. Returns slice of buf, or null if
/// neither XDG_CONFIG_HOME nor HOME is set.
pub fn resolveSkillsDir(buf: *[512]u8) ?[]const u8 {
    const env_xdg = libc.getenv("XDG_CONFIG_HOME");
    if (env_xdg != null) {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(env_xdg.?)));
        return std.fmt.bufPrint(buf, "{s}/mast/skills", .{s}) catch return null;
    }
    const env_home = libc.getenv("HOME");
    if (env_home != null) {
        const h = std.mem.span(@as([*:0]const u8, @ptrCast(env_home.?)));
        return std.fmt.bufPrint(buf, "{s}/.config/mast/skills", .{h}) catch return null;
    }
    return null;
}

/// Scan a directory for *.janet skills, descending one level into subdirs.
/// Silently skips entries that fail to parse (missing name field, I/O error).
fn scanDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    list: *std.ArrayList(Skill),
) !void {
    var path_z_buf: [512]u8 = undefined;
    if (dir_path.len >= path_z_buf.len) return;
    @memcpy(path_z_buf[0..dir_path.len], dir_path);
    path_z_buf[dir_path.len] = 0;

    const d = libc.opendir(@ptrCast(&path_z_buf));
    if (d == null) return; // directory does not exist — silently ok

    defer _ = libc.closedir(d);

    while (libc.readdir(d)) |entry| {
        const ename_ptr: [*:0]const u8 = @ptrCast(&entry.*.d_name);
        const ename = std.mem.span(ename_ptr);
        if (ename[0] == '.') continue; // skip . .. and hidden

        var child_path_buf: [1024]u8 = undefined;
        const child_path = std.fmt.bufPrint(
            &child_path_buf,
            "{s}/{s}",
            .{ dir_path, ename },
        ) catch continue;

        // stat to distinguish regular files from directories
        var child_z: [1024]u8 = undefined;
        if (child_path.len >= child_z.len) continue;
        @memcpy(child_z[0..child_path.len], child_path);
        child_z[child_path.len] = 0;

        var st: libc.struct_stat = undefined;
        if (libc.stat(@ptrCast(&child_z), &st) != 0) continue;

        const ifmt = st.st_mode & libc.S_IFMT;
        if (ifmt == libc.S_IFDIR) {
            // One level of recursion for category subdirs (e.g. skills/verification/)
            scanDir(allocator, child_path, list) catch {};
        } else if (ifmt == libc.S_IFREG and std.mem.endsWith(u8, ename, ".janet")) {
            const skill = parseSkillFile(allocator, child_path) catch continue;
            list.append(allocator, skill) catch |e| {
                var s = skill;
                s.deinit();
                return e;
            };
        }
    }
}

/// Read and parse a single skill file. Returns error if the file is
/// unreadable or missing the required `name:` frontmatter field.
pub fn parseSkillFile(allocator: std.mem.Allocator, path: []const u8) !Skill {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return Error.ReadFailed;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    // O_CLOEXEC: spawned children must not inherit the skill source fd.
    const fd = libc.open(@ptrCast(&path_z), libc.O_RDONLY | libc.O_CLOEXEC);
    if (fd < 0) return Error.OpenFailed;
    defer _ = libc.close(fd);

    // 64 KB cap, same as init.janet (large skills should be refactored).
    const MAX: usize = 65536;
    const raw_buf = try allocator.alloc(u8, MAX);
    defer allocator.free(raw_buf);

    const rc = libc.read(fd, raw_buf.ptr, MAX - 1);
    if (rc <= 0) return Error.ReadFailed;
    const len: usize = @intCast(rc);
    raw_buf[len] = 0;
    const raw = raw_buf[0..len];

    // Parse comment-header frontmatter. Stop at the first non-comment line.
    var name_val: []const u8 = "";
    var version_val: []const u8 = "0.1.0";
    var category_val: []const u8 = "misc";
    var description_val: []const u8 = "";
    var requires_cap: ?Capability = null;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue; // blank lines OK in frontmatter
        if (!std.mem.startsWith(u8, trimmed, "#")) break; // end of frontmatter
        const rest = std.mem.trimStart(u8, trimmed[1..], " \t");
        if (std.mem.startsWith(u8, rest, "name:")) {
            name_val = std.mem.trim(u8, rest[5..], " \t");
        } else if (std.mem.startsWith(u8, rest, "version:")) {
            version_val = std.mem.trim(u8, rest[8..], " \t");
        } else if (std.mem.startsWith(u8, rest, "category:")) {
            category_val = std.mem.trim(u8, rest[9..], " \t");
        } else if (std.mem.startsWith(u8, rest, "description:")) {
            description_val = std.mem.trim(u8, rest[12..], " \t");
        } else if (std.mem.startsWith(u8, rest, "requires:")) {
            requires_cap = parseCapability(std.mem.trim(u8, rest[9..], " \t"));
        }
    }

    if (name_val.len == 0) return Error.MissingName;

    return Skill{
        .name = try allocator.dupe(u8, name_val),
        .version = try allocator.dupe(u8, version_val),
        .category = try allocator.dupe(u8, category_val),
        .description = try allocator.dupe(u8, description_val),
        .required_cap = requires_cap,
        .source = try allocator.dupe(u8, raw),
        .path = try allocator.dupe(u8, path),
        .allocator = allocator,
    };
}

fn parseCapability(s: []const u8) ?Capability {
    if (std.mem.eql(u8, s, "exec")) return .exec;
    if (std.mem.eql(u8, s, "fs_read")) return .fs_read;
    if (std.mem.eql(u8, s, "fs_write")) return .fs_write;
    if (std.mem.eql(u8, s, "net_connect")) return .net_connect;
    if (std.mem.eql(u8, s, "net_listen")) return .net_listen;
    if (std.mem.eql(u8, s, "env_read")) return .env_read;
    if (std.mem.eql(u8, s, "env_write")) return .env_write;
    return null;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "parseCapability: known values round-trip" {
    try std.testing.expectEqual(Capability.exec, parseCapability("exec").?);
    try std.testing.expectEqual(Capability.fs_read, parseCapability("fs_read").?);
    try std.testing.expectEqual(Capability.fs_write, parseCapability("fs_write").?);
    try std.testing.expectEqual(Capability.net_connect, parseCapability("net_connect").?);
    try std.testing.expectEqual(Capability.net_listen, parseCapability("net_listen").?);
    try std.testing.expectEqual(Capability.env_read, parseCapability("env_read").?);
    try std.testing.expectEqual(Capability.env_write, parseCapability("env_write").?);
    try std.testing.expect(parseCapability("unknown") == null);
    try std.testing.expect(parseCapability("") == null);
}

test "parseSkillFile: parses all frontmatter fields" {
    const allocator = std.testing.allocator;

    const content =
        \\# name: my-skill
        \\# version: 1.2.3
        \\# category: verification
        \\# description: Does a thing
        \\# requires: exec
        \\
        \\(defn run [& args]
        \\  (string "done"))
    ;

    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(
        &tmp_path_buf,
        "/tmp/mast-skill-test-{d}.janet",
        .{@as(u64, @intCast(libc.getpid()))},
    );
    var path_z: [256]u8 = undefined;
    @memcpy(path_z[0..tmp_path.len], tmp_path);
    path_z[tmp_path.len] = 0;

    const wfd = libc.open(@ptrCast(&path_z), libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC | libc.O_CLOEXEC, @as(c_uint, 0o644));
    try std.testing.expect(wfd >= 0);
    _ = libc.write(wfd, content.ptr, content.len);
    _ = libc.close(wfd);
    defer _ = libc.unlink(@ptrCast(&path_z));

    var skill = try parseSkillFile(allocator, tmp_path);
    defer skill.deinit();

    try std.testing.expectEqualStrings("my-skill", skill.name);
    try std.testing.expectEqualStrings("1.2.3", skill.version);
    try std.testing.expectEqualStrings("verification", skill.category);
    try std.testing.expectEqualStrings("Does a thing", skill.description);
    try std.testing.expectEqual(Capability.exec, skill.required_cap.?);
    try std.testing.expect(skill.source.len > 0);
    try std.testing.expectEqualStrings(tmp_path, skill.path);
}

test "parseSkillFile: missing name returns MissingName error" {
    const allocator = std.testing.allocator;

    const content =
        \\# version: 0.1.0
        \\
        \\(defn run [] nil)
    ;

    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(
        &tmp_path_buf,
        "/tmp/mast-skill-noname-{d}.janet",
        .{@as(u64, @intCast(libc.getpid()))},
    );
    var path_z: [256]u8 = undefined;
    @memcpy(path_z[0..tmp_path.len], tmp_path);
    path_z[tmp_path.len] = 0;

    const wfd = libc.open(@ptrCast(&path_z), libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC | libc.O_CLOEXEC, @as(c_uint, 0o644));
    try std.testing.expect(wfd >= 0);
    _ = libc.write(wfd, content.ptr, content.len);
    _ = libc.close(wfd);
    defer _ = libc.unlink(@ptrCast(&path_z));

    const result = parseSkillFile(allocator, tmp_path);
    try std.testing.expectError(Error.MissingName, result);
}

test "parseSkillFile: no requires defaults to null capability" {
    const allocator = std.testing.allocator;

    const content =
        \\# name: no-cap-skill
        \\
        \\(defn run [] "ok")
    ;

    var tmp_path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(
        &tmp_path_buf,
        "/tmp/mast-skill-nocap-{d}.janet",
        .{@as(u64, @intCast(libc.getpid()))},
    );
    var path_z: [256]u8 = undefined;
    @memcpy(path_z[0..tmp_path.len], tmp_path);
    path_z[tmp_path.len] = 0;

    const wfd = libc.open(@ptrCast(&path_z), libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC | libc.O_CLOEXEC, @as(c_uint, 0o644));
    try std.testing.expect(wfd >= 0);
    _ = libc.write(wfd, content.ptr, content.len);
    _ = libc.close(wfd);
    defer _ = libc.unlink(@ptrCast(&path_z));

    var skill = try parseSkillFile(allocator, tmp_path);
    defer skill.deinit();

    try std.testing.expectEqualStrings("no-cap-skill", skill.name);
    try std.testing.expect(skill.required_cap == null);
}

test "Skills.find: locates skill by name" {
    const allocator = std.testing.allocator;

    // Build a minimal Skills without going through loadSkills (avoids fs)
    const registry = try allocator.create(Skills);
    const items = try allocator.alloc(Skill, 2);
    items[0] = Skill{
        .name = try allocator.dupe(u8, "alpha"),
        .version = try allocator.dupe(u8, "0.1.0"),
        .category = try allocator.dupe(u8, "misc"),
        .description = try allocator.dupe(u8, ""),
        .required_cap = null,
        .source = try allocator.dupe(u8, "(defn run [] nil)"),
        .path = try allocator.dupe(u8, "/tmp/alpha.janet"),
        .allocator = allocator,
    };
    items[1] = Skill{
        .name = try allocator.dupe(u8, "beta"),
        .version = try allocator.dupe(u8, "0.1.0"),
        .category = try allocator.dupe(u8, "misc"),
        .description = try allocator.dupe(u8, ""),
        .required_cap = Capability.exec,
        .source = try allocator.dupe(u8, "(defn run [] nil)"),
        .path = try allocator.dupe(u8, "/tmp/beta.janet"),
        .allocator = allocator,
    };
    registry.* = .{ .items = items, .allocator = allocator };
    defer registry.deinit();

    try std.testing.expect(registry.find("alpha") != null);
    try std.testing.expectEqualStrings("alpha", registry.find("alpha").?.name);
    try std.testing.expect(registry.find("beta") != null);
    try std.testing.expect(registry.find("gamma") == null);
}
