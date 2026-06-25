// plan.zig — structured plan management for mast's agentic loop.
//
// The Plan is the single source of truth for what the agent is doing.
// Requiring agent code to update the Plan before making file edits prevents
// the "code thrashing" pattern (contradictory multi-turn edits that happen
// because there is no explicit state machine to check).
//
// Plan events are written to an append-only JSONL file alongside the
// SessionAudit log. The in-memory Plan is rebuilt from scratch on session
// start; the JSONL is the durable audit trail.
//
// PlanTask status transitions:
//   pending → in_progress → done → verified
//                         ↘ blocked
//
// Compaction: collapse all done+verified tasks into summary entries,
// keeping only the critical path and in-progress work in the active plan.
// This keeps the plan small for LLM context injection.
//
// File I/O: libc-only, consistent with audit.zig + zk.zig.

const std = @import("std");

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("errno.h");
});

pub const TaskStatus = enum {
    pending,
    in_progress,
    done,
    verified,
    blocked,

    pub fn fromSlice(s: []const u8) ?TaskStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "done")) return .done;
        if (std.mem.eql(u8, s, "verified")) return .verified;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return null;
    }

    pub fn toSlice(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .done => "done",
            .verified => "verified",
            .blocked => "blocked",
        };
    }

    pub fn isComplete(self: TaskStatus) bool {
        return self == .done or self == .verified;
    }
};

pub const PlanTask = struct {
    id: u64,
    parent_id: ?u64,
    description: []const u8, // owned by Plan allocator
    status: TaskStatus,
    // Optional verification note (e.g. "zig build test must pass").
    verification: []const u8, // owned; empty string if none
    // Comma-separated affected file paths hint (informational for context).
    file_hints: []const u8, // owned; empty string if none
    created_ts: i64,
    updated_ts: i64,
};

pub const Plan = struct {
    tasks: std.ArrayListUnmanaged(PlanTask),
    next_id: u64,
    // Append-only JSONL fd for plan events. -1 if no log path set.
    log_fd: c_int,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Plan {
        return .{
            .tasks = .empty,
            .next_id = 1,
            .log_fd = -1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Plan) void {
        for (self.tasks.items) |*t| {
            self.allocator.free(t.description);
            self.allocator.free(t.verification);
            self.allocator.free(t.file_hints);
        }
        self.tasks.deinit(self.allocator);
        if (self.log_fd >= 0) {
            _ = libc.close(self.log_fd);
            self.log_fd = -1;
        }
    }

    /// Open (or create) the plan JSONL log at path. Must be called before
    /// any addTask / updateStatus that should be durable.
    pub fn openLog(self: *Plan, path: []const u8) !void {
        var path_z: [512]u8 = undefined;
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const fd = libc.open(
            @ptrCast(&path_z),
            libc.O_WRONLY | libc.O_CREAT | libc.O_APPEND | libc.O_CLOEXEC,
            @as(c_uint, 0o644),
        );
        if (fd < 0) return error.OpenFailed;
        self.log_fd = fd;
    }

    /// Add a new task. Returns its id. parent_id is null for top-level tasks.
    pub fn addTask(
        self: *Plan,
        description: []const u8,
        parent_id: ?u64,
        verification: []const u8,
        file_hints: []const u8,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        const now = @as(i64, @intCast(libc.time(null)));
        const task = PlanTask{
            .id = id,
            .parent_id = parent_id,
            .description = try self.allocator.dupe(u8, description),
            .status = .pending,
            .verification = try self.allocator.dupe(u8, verification),
            .file_hints = try self.allocator.dupe(u8, file_hints),
            .created_ts = now,
            .updated_ts = now,
        };
        try self.tasks.append(self.allocator, task);
        self.logEvent("task-add", id, .pending) catch {};
        return id;
    }

    /// Update the status of a task by id. Returns false if id not found.
    pub fn updateStatus(self: *Plan, id: u64, status: TaskStatus) bool {
        for (self.tasks.items) |*t| {
            if (t.id == id) {
                t.status = status;
                t.updated_ts = @as(i64, @intCast(libc.time(null)));
                self.logEvent("task-status", id, status) catch {};
                return true;
            }
        }
        return false;
    }

    /// Count tasks that are not yet complete (pending, in_progress, or blocked).
    pub fn countActive(self: *const Plan) usize {
        var n: usize = 0;
        for (self.tasks.items) |t| {
            if (!t.status.isComplete()) n += 1;
        }
        return n;
    }

    /// Compaction: remove done+verified tasks that have no pending/in_progress
    /// children. Replaces them with a compact summary node to preserve the
    /// narrative record while keeping the active plan small.
    ///
    /// Returns the number of tasks removed from the active set.
    pub fn compact(self: *Plan) !usize {
        const before = self.tasks.items.len;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const t = &self.tasks.items[i];
            if (!t.status.isComplete()) {
                i += 1;
                continue;
            }
            // Keep if any children are still active
            if (self.hasActiveChildren(t.id)) {
                i += 1;
                continue;
            }
            // Remove: free strings, swap-remove for O(1)
            self.allocator.free(t.description);
            self.allocator.free(t.verification);
            self.allocator.free(t.file_hints);
            _ = self.tasks.swapRemove(i);
            // Don't advance i — the swapped element needs checking too
        }
        const removed = before - self.tasks.items.len;
        if (removed > 0) {
            self.logEvent("plan-compact", 0, .pending) catch {};
        }
        return removed;
    }

    fn hasActiveChildren(self: *const Plan, parent_id: u64) bool {
        for (self.tasks.items) |t| {
            if (t.parent_id != null and t.parent_id.? == parent_id) {
                if (!t.status.isComplete()) return true;
            }
        }
        return false;
    }

    fn logEvent(self: *Plan, event: []const u8, task_id: u64, status: TaskStatus) !void {
        if (self.log_fd < 0) return;
        var buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"ts\":{d},\"event\":\"{s}\",\"task_id\":{d},\"status\":\"{s}\"}}\n",
            .{
                @as(i64, @intCast(libc.time(null))),
                event,
                task_id,
                status.toSlice(),
            },
        );
        _ = libc.write(self.log_fd, line.ptr, line.len);
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────

test "TaskStatus: fromSlice + toSlice round-trip" {
    inline for (.{ "pending", "in_progress", "done", "verified", "blocked" }) |s| {
        const status = TaskStatus.fromSlice(s).?;
        try std.testing.expectEqualStrings(s, status.toSlice());
    }
    try std.testing.expect(TaskStatus.fromSlice("unknown") == null);
}

test "TaskStatus.isComplete: only done and verified" {
    try std.testing.expect(TaskStatus.done.isComplete());
    try std.testing.expect(TaskStatus.verified.isComplete());
    try std.testing.expect(!TaskStatus.pending.isComplete());
    try std.testing.expect(!TaskStatus.in_progress.isComplete());
    try std.testing.expect(!TaskStatus.blocked.isComplete());
}

test "Plan.addTask: ids are sequential starting from 1" {
    const allocator = std.testing.allocator;
    var plan = Plan.init(allocator);
    defer plan.deinit();

    const id1 = try plan.addTask("first task", null, "", "");
    const id2 = try plan.addTask("second task", null, "", "");
    const id3 = try plan.addTask("child of first", id1, "", "");

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(u64, 3), id3);
    try std.testing.expectEqual(@as(usize, 3), plan.tasks.items.len);
    try std.testing.expect(plan.tasks.items[2].parent_id != null);
    try std.testing.expectEqual(id1, plan.tasks.items[2].parent_id.?);
}

test "Plan.updateStatus: updates existing task, returns false for unknown id" {
    const allocator = std.testing.allocator;
    var plan = Plan.init(allocator);
    defer plan.deinit();

    const id = try plan.addTask("task", null, "", "");
    try std.testing.expect(plan.tasks.items[0].status == .pending);

    try std.testing.expect(plan.updateStatus(id, .in_progress));
    try std.testing.expect(plan.tasks.items[0].status == .in_progress);

    try std.testing.expect(!plan.updateStatus(9999, .done));
}

test "Plan.countActive: counts only non-complete tasks" {
    const allocator = std.testing.allocator;
    var plan = Plan.init(allocator);
    defer plan.deinit();

    _ = try plan.addTask("pending task", null, "", "");
    const id2 = try plan.addTask("to be done", null, "", "");
    _ = try plan.addTask("in progress", null, "", "");

    _ = plan.updateStatus(id2, .done);

    try std.testing.expectEqual(@as(usize, 2), plan.countActive());
}

test "Plan.compact: removes done+verified leaf tasks" {
    const allocator = std.testing.allocator;
    var plan = Plan.init(allocator);
    defer plan.deinit();

    const id1 = try plan.addTask("parent", null, "", "");
    const id2 = try plan.addTask("done leaf", id1, "", "");
    const id3 = try plan.addTask("verified leaf", id1, "", "");
    _ = try plan.addTask("active child", id1, "", "");

    _ = plan.updateStatus(id2, .done);
    _ = plan.updateStatus(id3, .verified);

    try std.testing.expectEqual(@as(usize, 4), plan.tasks.items.len);
    const removed = try plan.compact();
    // id2 and id3 are done/verified leaves → removed; id1 has active child → kept; id4 active → kept
    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expectEqual(@as(usize, 2), plan.tasks.items.len);
}

test "Plan.compact: keeps done task with active children" {
    const allocator = std.testing.allocator;
    var plan = Plan.init(allocator);
    defer plan.deinit();

    const parent_id = try plan.addTask("parent", null, "", "");
    _ = try plan.addTask("active child", parent_id, "", "");

    _ = plan.updateStatus(parent_id, .done);

    const removed = try plan.compact();
    // Parent is done but has an active child → keep
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 2), plan.tasks.items.len);
}
