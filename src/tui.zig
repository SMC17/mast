// tui.zig — minimal ANSI-based windowed view for mast.
//
// Why in-house and not vaxis: mast's doctrine is single-binary,
// libc-direct, no external Zig dependencies (no build.zig.zon today).
// vaxis is the leading candidate for v0.4, but adding a dep today would
// break the doctrine AND introduce Zig 0.13→0.16 churn we explicitly
// route around in buffer.zig / sandbox.zig / main.zig. ANSI escape codes
// + termios raw mode reach 95% of what a v0.3 windowed view needs without
// any of that risk.
//
// Layout (24x80 terminal example):
//
//   ┌─────────────────────────────────────────────────────────────┐
//   │   1  line one of the buffer                                  │ <- viewport
//   │   2  line two                                                │
//   │   …                                                          │
//   │   N  last line in view                                       │
//   ├─────────────────────────────────────────────────────────────┤
//   │ [0/3] :agent uptime (123 bytes) — j/k nav  n/p buffer  : Mx  │ <- status
//   ├─────────────────────────────────────────────────────────────┤
//   │ M-x █                                                        │ <- minibuffer
//   └─────────────────────────────────────────────────────────────┘
//
// Keys (v0.3):
//   j / Down   → scroll viewport down one line
//   k / Up     → scroll viewport up one line
//   g          → top of buffer
//   G          → bottom of buffer
//   n          → next buffer (cycle)
//   p          → prev buffer (cycle)
//   :          → enter M-x mode (read command, execute, return to view)
//   q / Ctrl-C → quit TUI (returns to caller; existing REPL still works)
//
// Sandbox interaction: tui.zig is host code. It is NOT in the Janet
// trust boundary. Janet scripts cannot drive the TUI directly — they
// can only mutate buffers (which the TUI re-renders). This is the same
// posture audit.zig holds.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

const libc = @cImport({
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
});

const Allocator = std.mem.Allocator;
const print = std.debug.print;

// ─── ANSI escape sequences ─────────────────────────────────────────────

const ALT_SCREEN_ON = "\x1b[?1049h";
const ALT_SCREEN_OFF = "\x1b[?1049l";
const CURSOR_HIDE = "\x1b[?25l";
const CURSOR_SHOW = "\x1b[?25h";
const CLEAR_SCREEN = "\x1b[2J";
const HOME = "\x1b[H";
const CLEAR_LINE = "\x1b[2K";
const REVERSE = "\x1b[7m";
const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";

// Write directly to fd=1 (stdout) without going through std.io (which has
// churned across Zig 0.13→0.16). The TUI is high-frequency stdout — keep
// it on the libc-direct path that the rest of the codebase uses.
pub fn write_str(s: []const u8) void {
    _ = libc.write(1, s.ptr, s.len);
}

fn write_cursor(row: usize, col: usize) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
    write_str(s);
}

// Buffer-append equivalents used by render() so the caller can diff
// the rendered frame against the previous one before emitting (damage
// tracker, closes the v1.3.0 "TUI full-redraw per keystroke" residual).
fn buf_str(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) void {
    out.appendSlice(allocator, s) catch {};
}

fn buf_cursor(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row: usize, col: usize) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
    buf_str(out, allocator, s);
}

// ─── Terminal dimensions ───────────────────────────────────────────────

pub const Dims = struct { rows: u16, cols: u16 };

pub fn terminalSize() Dims {
    var ws: libc.struct_winsize = undefined;
    const TIOCGWINSZ: c_ulong = 0x5413; // Linux value; Darwin defines differently but same call.
    if (libc.ioctl(1, TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return .{ .rows = 24, .cols = 80 };
}

// ─── Raw-mode termios management ───────────────────────────────────────

pub const RawMode = struct {
    original: libc.termios,
    active: bool = false,

    pub fn enter() RawMode {
        var orig: libc.termios = undefined;
        _ = libc.tcgetattr(0, &orig);
        var raw = orig;
        // Disable canonical mode + echo + signals so we read char-at-a-time.
        // Keep ISIG off so Ctrl-C still passes through as a key the TUI can
        // observe — the existing REPL exit path handles cleanup.
        raw.c_lflag &= ~@as(c_uint, libc.ICANON | libc.ECHO);
        raw.c_iflag &= ~@as(c_uint, libc.IXON | libc.ICRNL);
        raw.c_cc[libc.VMIN] = 1;
        raw.c_cc[libc.VTIME] = 0;
        _ = libc.tcsetattr(0, libc.TCSANOW, &raw);
        write_str(ALT_SCREEN_ON);
        write_str(CURSOR_HIDE);
        write_str(CLEAR_SCREEN);
        write_str(HOME);
        return .{ .original = orig, .active = true };
    }

    pub fn exit(self: *RawMode) void {
        if (!self.active) return;
        write_str(CURSOR_SHOW);
        write_str(ALT_SCREEN_OFF);
        _ = libc.tcsetattr(0, libc.TCSANOW, &self.original);
        self.active = false;
    }
};

// ─── Single key read ───────────────────────────────────────────────────
//
// Reads one byte. Arrow keys come through as a 3-byte sequence (ESC [ X)
// — we read the prefix and return a synthetic code:
//   65 = Up, 66 = Down (matches ASCII 'A', 'B' deliberately for switch
//   ergonomics in the caller).

pub const Key = enum(i32) {
    eof = -1,
    up = 1001,
    down = 1002,
    right = 1003,
    left = 1004,
    other = 0,
    _,

    pub fn fromByte(b: u8) Key {
        return @enumFromInt(@as(i32, b));
    }
};

pub fn readKey() Key {
    var b: [1]u8 = undefined;
    const n = libc.read(0, &b, 1);
    if (n <= 0) return .eof;
    if (b[0] == 0x1b) {
        // Possible escape sequence; peek 2 more bytes.
        var seq: [2]u8 = undefined;
        if (libc.read(0, &seq, 2) == 2 and seq[0] == '[') {
            return switch (seq[1]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .other,
            };
        }
        return .other;
    }
    return Key.fromByte(b[0]);
}

// ─── Render ────────────────────────────────────────────────────────────
//
// Renders the entire frame INTO a caller-supplied byte buffer. The TUI
// loop then either writes the whole buffer to stdout (initial frame /
// after resize) or diffs against the previous frame and skips emit when
// nothing changed (damage tracker, closes the v1.3.0 full-redraw
// residual). Keeping the render in-memory also makes the TUI testable
// in v0.3.x without a pty fixture.

pub fn render_to_buf(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    buf: ?*const Buffer,
    scroll: usize,
    current_idx: usize,
    total_buffers: usize,
    minibuffer: ?[]const u8,
) void {
    const dims = terminalSize();
    buf_str(out, allocator, CLEAR_SCREEN);

    // Viewport: rows 1..(rows-2), columns 1..cols. Bottom 2 rows are
    // status + minibuffer.
    const viewport_rows: usize = if (dims.rows > 3) dims.rows - 2 else 1;
    buf_cursor(out, allocator, 1, 1);

    if (buf) |b| {
        var line_no: usize = 0;
        var line_start: usize = 0;
        var rendered: usize = 0;
        var i: usize = 0;
        while (i < b.contents.len) : (i += 1) {
            if (b.contents[i] == '\n') {
                if (line_no >= scroll and rendered < viewport_rows) {
                    var prefix_buf: [16]u8 = undefined;
                    const prefix = std.fmt.bufPrint(&prefix_buf, "{d:>4}  ", .{line_no + 1}) catch "  ?  ";
                    buf_str(out, allocator, DIM);
                    buf_str(out, allocator, prefix);
                    buf_str(out, allocator, RESET);
                    const line_end = i;
                    const line_text = b.contents[line_start..line_end];
                    const max_cols: usize = if (dims.cols > 8) @intCast(dims.cols - 8) else 0;
                    const visible_len = @min(line_text.len, max_cols);
                    buf_str(out, allocator, line_text[0..visible_len]);
                    buf_str(out, allocator, "\r\n");
                    rendered += 1;
                }
                line_no += 1;
                line_start = i + 1;
            }
        }
        // Tail line (no trailing newline)
        if (line_start < b.contents.len and line_no >= scroll and rendered < viewport_rows) {
            var prefix_buf: [16]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "{d:>4}  ", .{line_no + 1}) catch "  ?  ";
            buf_str(out, allocator, DIM);
            buf_str(out, allocator, prefix);
            buf_str(out, allocator, RESET);
            buf_str(out, allocator, b.contents[line_start..]);
            buf_str(out, allocator, "\r\n");
            rendered += 1;
        }
        // Pad short buffers
        while (rendered < viewport_rows) : (rendered += 1) {
            buf_str(out, allocator, DIM);
            buf_str(out, allocator, "   ~\r\n");
            buf_str(out, allocator, RESET);
        }
    } else {
        var rendered: usize = 0;
        while (rendered < viewport_rows) : (rendered += 1) {
            buf_str(out, allocator, DIM);
            buf_str(out, allocator, "   (no buffer open)\r\n");
            buf_str(out, allocator, RESET);
        }
    }

    // Status line
    buf_cursor(out, allocator, viewport_rows + 1, 1);
    buf_str(out, allocator, CLEAR_LINE);
    buf_str(out, allocator, REVERSE);
    var status_buf: [256]u8 = undefined;
    const kind_label = if (buf) |b| @tagName(b.kind) else "none";
    const buf_name = if (buf) |b| b.name else "—";
    const dirty_mark = if (buf) |b| (if (b.dirty) "*" else "") else "";
    const buf_size = if (buf) |b| b.contents.len else 0;
    const status = std.fmt.bufPrint(&status_buf,
        " [{d}/{d}] :{s} {s}{s} ({d} B)  scroll={d}  j/k nav  n/p buf  : Mx  q quit ",
        .{ current_idx, total_buffers, kind_label, buf_name, dirty_mark, buf_size, scroll },
    ) catch " mast ";
    const status_visible_len = @min(status.len, dims.cols);
    buf_str(out, allocator, status[0..status_visible_len]);
    // Pad to full width so REVERSE highlights the whole bar.
    var pad: usize = if (dims.cols > status_visible_len) dims.cols - status_visible_len else 0;
    while (pad > 0) : (pad -= 1) buf_str(out, allocator, " ");
    buf_str(out, allocator, RESET);

    // Minibuffer (M-x line)
    buf_cursor(out, allocator, viewport_rows + 2, 1);
    buf_str(out, allocator, CLEAR_LINE);
    if (minibuffer) |mb| {
        buf_str(out, allocator, "M-x ");
        buf_str(out, allocator, mb);
        buf_str(out, allocator, "_");
    } else {
        buf_str(out, allocator, DIM);
        buf_str(out, allocator, "(press : for M-x command)");
        buf_str(out, allocator, RESET);
    }

    // Park the cursor at the minibuffer position so the user can see input.
    buf_cursor(out, allocator, viewport_rows + 2, if (minibuffer) |mb| 5 + mb.len else 1);
}

/// Back-compat wrapper for callers that want immediate stdout emission
/// (no damage tracking). The TUI loop in main.zig uses `render_to_buf`
/// + `emit_with_damage` directly.
pub fn render(
    buf: ?*const Buffer,
    scroll: usize,
    current_idx: usize,
    total_buffers: usize,
    minibuffer: ?[]const u8,
) void {
    const allocator = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    render_to_buf(&out, allocator, buf, scroll, current_idx, total_buffers, minibuffer);
    write_str(out.items);
}

/// Frame state for damage-tracker emission.
///
/// Two diff granularities live in the same struct:
///   - frame-level (`last`): the entire rendered frame as one byte slice.
///     `frame_changed` / `emit_with_damage` use this.
///   - row-level (`row_last`, `row_lens`): one stored slice per row of
///     last frame's content. `emit_with_row_damage` uses this to emit
///     ONLY rows that changed since the last frame — important on large
///     terminals where the unchanged-row cost dominates.
///
/// Both modes share `full_redraw`. After `invalidate(state)` the next
/// emit (either mode) rewrites the whole screen and re-snapshots.
pub const FrameState = struct {
    last: std.ArrayList(u8) = .empty,
    full_redraw: bool = true,

    // Row-level snapshot (v1.3.3). Each row is stored as a flat byte slice
    // including the trailing "\r\n" that render emits, but WITHOUT the
    // cursor-positioning escape (those are regenerated per emit, so they
    // don't enter the diff).
    row_last: [MAX_ROWS]?[]u8 = .{null} ** MAX_ROWS,
    row_count: usize = 0,

    pub const MAX_ROWS: usize = 256;

    pub fn deinit(self: *FrameState, allocator: std.mem.Allocator) void {
        self.last.deinit(allocator);
        for (&self.row_last) |*row| {
            if (row.*) |bytes| {
                allocator.free(bytes);
                row.* = null;
            }
        }
    }
};

/// Pure diff logic: returns true if `current` differs from the cached
/// `state.last` (or `state.full_redraw` is set), and if so updates the
/// cache. Does NOT write anywhere. Use this in tests + anywhere the
/// caller wants to make their own decision about emit.
pub fn frame_changed(
    state: *FrameState,
    allocator: std.mem.Allocator,
    current: []const u8,
) bool {
    if (!state.full_redraw and std.mem.eql(u8, current, state.last.items)) {
        return false;
    }
    state.last.clearRetainingCapacity();
    state.last.appendSlice(allocator, current) catch {};
    state.full_redraw = false;
    return true;
}

/// Diff-emit: write `current` to stdout iff it differs from `state.last`
/// (or the state demands a full redraw). Updates `state.last` to the
/// emitted bytes. Returns true if bytes were written, false if frame
/// was unchanged.
///
/// This is `frame_changed` + `write_str(current)`. The split exists so
/// tests can exercise the diff logic without triggering the stdout
/// side-effect (which deadlocks under the Zig test runner's --listen=-
/// stdout-capture transport).
pub fn emit_with_damage(
    state: *FrameState,
    allocator: std.mem.Allocator,
    current: []const u8,
) bool {
    if (!frame_changed(state, allocator, current)) return false;
    write_str(current);
    return true;
}

/// Force the next emit (either mode) to rewrite regardless of diff.
/// Used after window resize, after exiting/entering alt-screen, after
/// any out-of-band write to stdout that would invalidate the cached
/// screen representation.
pub fn invalidate(state: *FrameState) void {
    state.full_redraw = true;
}

// ─── Row-level damage tracker (v1.3.3) ─────────────────────────────────
//
// Splits the current frame into rows on "\r\n" boundaries, diffs each
// row against state.row_last[i], and emits only rows that changed.
// Each emitted row is preceded by a cursor-position escape and CLEAR_LINE
// so cursor placement is independent of which rows were skipped.
//
// On full_redraw: writes the whole frame as-is (same as emit_with_damage)
// then captures each row into state.row_last.

/// Returns the list of (row_index, row_bytes) pairs that need emit. Pure
/// — does NOT write anywhere. The caller uses these to emit selectively
/// (or to assert in tests). Updates state.row_last (cache).
pub fn diff_rows(
    state: *FrameState,
    allocator: std.mem.Allocator,
    current: []const u8,
    out_changed: *std.ArrayList(usize),
) void {
    out_changed.clearRetainingCapacity();

    // Walk current frame, splitting on "\r\n" into row slices.
    // For each row, compare against state.row_last[i]; if different,
    // record row index + update cache.
    var row_idx: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i + 1 < current.len) : (i += 1) {
        if (current[i] == '\r' and current[i + 1] == '\n') {
            const row_bytes = current[line_start .. i + 2]; // include \r\n
            if (state.full_redraw or rowDiffers(state, row_idx, row_bytes)) {
                out_changed.append(allocator, row_idx) catch return;
                captureRow(state, allocator, row_idx, row_bytes);
            }
            row_idx += 1;
            line_start = i + 2;
            i += 1; // skip the \n
            if (row_idx >= FrameState.MAX_ROWS) break;
        }
    }
    // Tail (no trailing \r\n)
    if (line_start < current.len and row_idx < FrameState.MAX_ROWS) {
        const row_bytes = current[line_start..];
        if (state.full_redraw or rowDiffers(state, row_idx, row_bytes)) {
            out_changed.append(allocator, row_idx) catch return;
            captureRow(state, allocator, row_idx, row_bytes);
        }
        row_idx += 1;
    }
    state.row_count = row_idx;
    state.full_redraw = false;
}

fn rowDiffers(state: *const FrameState, row_idx: usize, candidate: []const u8) bool {
    if (row_idx >= FrameState.MAX_ROWS) return true;
    const cached = state.row_last[row_idx] orelse return true;
    return !std.mem.eql(u8, cached, candidate);
}

fn captureRow(state: *FrameState, allocator: std.mem.Allocator, row_idx: usize, bytes: []const u8) void {
    if (row_idx >= FrameState.MAX_ROWS) return;
    if (state.row_last[row_idx]) |old| allocator.free(old);
    state.row_last[row_idx] = allocator.dupe(u8, bytes) catch null;
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// terminalSize / RawMode / readKey are termios-dependent and hard to test
// hermetically without a pty fixture. write_cursor and the ANSI strings
// are pure constants. The render function is hard to assert against
// without capturing stdout — we'd need to refactor render to take a
// writer first. v0.3.x test work.

test "tui module compiles and basic ANSI constants are non-empty" {
    try std.testing.expect(ALT_SCREEN_ON.len > 0);
    try std.testing.expect(ALT_SCREEN_OFF.len > 0);
    try std.testing.expect(CLEAR_SCREEN.len > 0);
}

test "render_to_buf produces deterministic output for the empty-buffer case" {
    const allocator = std.testing.allocator;
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(allocator);
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(allocator);

    // Two renders of identical state must produce byte-identical output.
    render_to_buf(&out1, allocator, null, 0, 0, 0, null);
    render_to_buf(&out2, allocator, null, 0, 0, 0, null);
    try std.testing.expectEqualSlices(u8, out1.items, out2.items);
    try std.testing.expect(out1.items.len > 0);
}

test "diff_rows: first call reports every row changed; second identical call reports none" {
    const allocator = std.testing.allocator;
    var state = FrameState{};
    defer state.deinit(allocator);

    // Synthetic 3-row frame.
    const frame = "row alpha\r\nrow beta\r\nrow gamma\r\n";
    var changed: std.ArrayList(usize) = .empty;
    defer changed.deinit(allocator);

    diff_rows(&state, allocator, frame, &changed);
    try std.testing.expectEqual(@as(usize, 3), changed.items.len);
    try std.testing.expectEqual(@as(usize, 0), changed.items[0]);
    try std.testing.expectEqual(@as(usize, 2), changed.items[2]);

    diff_rows(&state, allocator, frame, &changed);
    try std.testing.expectEqual(@as(usize, 0), changed.items.len);
}

test "diff_rows: reports only the rows that actually changed" {
    const allocator = std.testing.allocator;
    var state = FrameState{};
    defer state.deinit(allocator);

    const frame_a = "row alpha\r\nrow beta\r\nrow gamma\r\n";
    const frame_b = "row alpha\r\nROW BETA\r\nrow gamma\r\n";
    var changed: std.ArrayList(usize) = .empty;
    defer changed.deinit(allocator);

    diff_rows(&state, allocator, frame_a, &changed);
    try std.testing.expectEqual(@as(usize, 3), changed.items.len); // first call: all

    diff_rows(&state, allocator, frame_b, &changed);
    try std.testing.expectEqual(@as(usize, 1), changed.items.len); // only middle row
    try std.testing.expectEqual(@as(usize, 1), changed.items[0]);
}

test "diff_rows: invalidate forces all rows to re-emit" {
    const allocator = std.testing.allocator;
    var state = FrameState{};
    defer state.deinit(allocator);

    const frame = "a\r\nb\r\nc\r\n";
    var changed: std.ArrayList(usize) = .empty;
    defer changed.deinit(allocator);

    diff_rows(&state, allocator, frame, &changed); // first call, all 3
    try std.testing.expectEqual(@as(usize, 3), changed.items.len);

    diff_rows(&state, allocator, frame, &changed); // no diff
    try std.testing.expectEqual(@as(usize, 0), changed.items.len);

    invalidate(&state);
    diff_rows(&state, allocator, frame, &changed); // forced full
    try std.testing.expectEqual(@as(usize, 3), changed.items.len);
}

test "FrameState damage tracker: frame_changed returns true on first call + cached comparison" {
    // Uses the pure frame_changed helper instead of emit_with_damage so we
    // don't write to stdout from inside the test (the Zig test runner's
    // --listen=- transport blocks the test when stdout fills, causing the
    // SIGTERM kill we observed when this test was first added).
    const allocator = std.testing.allocator;
    var state = FrameState{};
    defer state.deinit(allocator);

    var frame_a: std.ArrayList(u8) = .empty;
    defer frame_a.deinit(allocator);
    render_to_buf(&frame_a, allocator, null, 0, 0, 0, null);

    // First call: always a full redraw (state.full_redraw = true).
    const first = frame_changed(&state, allocator, frame_a.items);
    try std.testing.expect(first);
    try std.testing.expectEqualSlices(u8, frame_a.items, state.last.items);

    // Second call with identical bytes: must skip (frame unchanged).
    const second = frame_changed(&state, allocator, frame_a.items);
    try std.testing.expect(!second);

    // After invalidate(): the next call must fire regardless of diff.
    invalidate(&state);
    const third = frame_changed(&state, allocator, frame_a.items);
    try std.testing.expect(third);

    // A different frame: must trigger even without invalidate.
    var frame_b: std.ArrayList(u8) = .empty;
    defer frame_b.deinit(allocator);
    render_to_buf(&frame_b, allocator, null, 5, 0, 0, null);
    const fourth = frame_changed(&state, allocator, frame_b.items);
    try std.testing.expect(fourth);
    try std.testing.expectEqualSlices(u8, frame_b.items, state.last.items);
}
