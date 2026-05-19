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
fn write_str(s: []const u8) void {
    _ = libc.write(1, s.ptr, s.len);
}

fn write_cursor(row: usize, col: usize) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
    write_str(s);
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

pub fn render(
    buf: ?*const Buffer,
    scroll: usize,
    current_idx: usize,
    total_buffers: usize,
    minibuffer: ?[]const u8,
) void {
    const dims = terminalSize();
    write_str(CLEAR_SCREEN);

    // Viewport: rows 1..(rows-2), columns 1..cols. Bottom 2 rows are
    // status + minibuffer.
    const viewport_rows: usize = if (dims.rows > 3) dims.rows - 2 else 1;
    write_cursor(1, 1);

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
                    write_str(DIM);
                    write_str(prefix);
                    write_str(RESET);
                    const line_end = i;
                    const line_text = b.contents[line_start..line_end];
                    const max_cols: usize = if (dims.cols > 8) @intCast(dims.cols - 8) else 0;
                    const visible_len = @min(line_text.len, max_cols);
                    write_str(line_text[0..visible_len]);
                    write_str("\r\n");
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
            write_str(DIM);
            write_str(prefix);
            write_str(RESET);
            write_str(b.contents[line_start..]);
            write_str("\r\n");
            rendered += 1;
        }
        // Pad short buffers
        while (rendered < viewport_rows) : (rendered += 1) {
            write_str(DIM);
            write_str("   ~\r\n");
            write_str(RESET);
        }
    } else {
        var rendered: usize = 0;
        while (rendered < viewport_rows) : (rendered += 1) {
            write_str(DIM);
            write_str("   (no buffer open)\r\n");
            write_str(RESET);
        }
    }

    // Status line
    write_cursor(viewport_rows + 1, 1);
    write_str(CLEAR_LINE);
    write_str(REVERSE);
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
    write_str(status[0..status_visible_len]);
    // Pad to full width so REVERSE highlights the whole bar.
    var pad: usize = if (dims.cols > status_visible_len) dims.cols - status_visible_len else 0;
    while (pad > 0) : (pad -= 1) write_str(" ");
    write_str(RESET);

    // Minibuffer (M-x line)
    write_cursor(viewport_rows + 2, 1);
    write_str(CLEAR_LINE);
    if (minibuffer) |mb| {
        write_str("M-x ");
        write_str(mb);
        write_str("_");
    } else {
        write_str(DIM);
        write_str("(press : for M-x command)");
        write_str(RESET);
    }

    // Park the cursor at the minibuffer position so the user can see input.
    write_cursor(viewport_rows + 2, if (minibuffer) |mb| 5 + mb.len else 1);
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
