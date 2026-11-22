const std = @import("std");
const build_options = @import("build_options");
const util = @import("util.zig");
const testing = std.testing;
const has_daemon = if (@hasDecl(build_options, "has_daemon")) build_options.has_daemon else true;
pub const ghostty_vt = if (has_daemon) @import("ghostty-vt") else struct {
    pub const Terminal = struct {};
    pub const Parser = struct {};
    pub const Selection = struct {};
    pub const formatter = struct {};
    pub const color = struct {};
};

pub const HistoryFormat = util.HistoryFormat;

pub fn isMouseReport(payload: []const u8) bool {
    if (payload.len == 0) return false;
    var pos: usize = 0;
    while (pos < payload.len) {
        if (consumeSgrMouseReport(payload[pos..])) |n| {
            pos += n;
        } else if (consumeLegacyMouseReport(payload[pos..])) |n| {
            pos += n;
        } else {
            return false;
        }
    }
    return true;
}

fn consumeSgrMouseReport(payload: []const u8) ?usize {
    if (!std.mem.startsWith(u8, payload, "\x1b[<")) return null;
    var pos: usize = 3;
    var field: usize = 0;
    while (field < 3) : (field += 1) {
        if (pos < payload.len and payload[pos] == '-') pos += 1;
        const digits_start = pos;
        while (pos < payload.len and payload[pos] >= '0' and payload[pos] <= '9') : (pos += 1) {}
        if (pos == digits_start) return null;
        if (field < 2) {
            if (pos >= payload.len or payload[pos] != ';') return null;
            pos += 1;
        }
    }
    if (pos >= payload.len) return null;
    return switch (payload[pos]) {
        'M', 'm' => pos + 1,
        else => null,
    };
}

fn consumeLegacyMouseReport(payload: []const u8) ?usize {
    if (!std.mem.startsWith(u8, payload, "\x1b[M") or payload.len < 6) return null;
    for (payload[3..6]) |b| if (b < 0x20) return null;
    return 6;
}

/// Detect if the payload contains user input that should be printed to the screen or
/// is a key combination like up-arrow, backspace, enter, ctrl+f, etc.
pub fn isUserInput(payload: []const u8) bool {
    var parser = ghostty_vt.Parser.init();
    var i: usize = 0;
    while (i < payload.len) {
        if (payload[i] == 0x1b and i + 2 < payload.len and payload[i + 1] == '[') {
            if (util.parseKittyCsiU(payload[i + 2 ..])) |kitty| {
                if (kitty.event_type != 3) return true;
                i += 2 + kitty.consumed;
                continue;
            }
        }

        // Replies start with ESC; bare C0 controls and DEL are keyboard input.
        if (i == 0 and ((payload[i] < 0x20 and payload[i] != 0x1b) or payload[i] == 0x7f)) return true;
        const actions = parser.next(payload[i]);
        for (actions) |action_opt| {
            const action = action_opt orelse continue;
            switch (action) {
                .print => return true, // printable characters
                .csi_dispatch => |csi| {
                    const private_reply = for (csi.intermediates) |b| {
                        if (b == '?' or b == '>' or b == '=' or b == '<') break true;
                    } else false;
                    if (private_reply) continue;
                    // kitty keyboard: CSI ... u or CSI ... ~
                    // legacy modified keys: CSI 27 ; ... ~
                    // arrow/function keys with modifiers: CSI 1 ; <mod> A-D
                    // CSI ? flags u is the terminal's reply to a kitty keyboard status
                    // query, not a key press; skip it and keep scanning the payload
                    const status_reply = csi.final == 'u' and csi.intermediates.len > 0 and csi.intermediates[0] == '?';
                    if (!status_reply and (csi.final == 'u' or csi.final == '~')) return true;
                    // Ordinary and modified CSI arrows are keyboard input.
                    if (csi.final >= 'A' and csi.final <= 'D' and csi.intermediates.len == 0) return true;
                    if (csi.intermediates.len == 0) {
                        if (csi.final == 'Z' and csi.params.len == 0) return true;
                        if (csi.final == 'H' or csi.final == 'F') {
                            // Home/End use no params or 1;<modifier>, unlike cursor positioning.
                            if (csi.params.len == 0 or
                                (csi.params.len == 2 and csi.params[0] == 1 and
                                    csi.params[1] >= 1 and !csi.params_sep.isSet(0))) return true;
                        }
                    }
                    // mouse events: CSI M (basic) or CSI < (SGR extended) - EXCLUDE these
                    // only intentional keyboard input should trigger leader switch
                    if (csi.final == 'M' or csi.final == '<') return false;
                    // focus events: CSI I (focus in) or CSI O (focus out) - EXCLUDE these
                    // these are automatic terminal events, not user typing
                    if (csi.final == 'I' or csi.final == 'O') return false;
                },
                .execute => |code| {
                    // looking for CR, LF, tab, and backspace
                    if (code == 0x0D or code == 0x0A or code == 0x09 or code == 0x08) return true;
                },
                else => {},
            }
        }
        i += 1;
    }
    return false;
}

/// Emit the terminal's pwd as OSC 7.
///
/// This replaces the formatter's own `extra.pwd`, which writes
/// `terminal.pwd.items` verbatim. `Terminal.setPwd` appends a NUL sentinel to
/// that buffer, so the formatter's OSC 7 carries a stray `\x00` before the
/// terminator. `getPwd()` returns the same bytes without the sentinel.
///
/// The NUL is not cosmetic: a client that records what it receives (kitty
/// writing its session file, for one) persists the NUL and then fails to parse
/// its own state back. See https://github.com/neurosnap/zmx/issues/222.
fn writePwd(writer: *std.Io.Writer, term: *const ghostty_vt.Terminal) void {
    const pwd = term.getPwd() orelse return;
    if (pwd.len == 0) return;
    writer.print("\x1b]7;{s}\x1b\\", .{pwd}) catch |err| {
        std.log.warn("failed to format pwd err={s}", .{@errorName(err)});
    };
}

fn writeDynamicColor(
    writer: *std.Io.Writer,
    kind: ghostty_vt.color.Dynamic,
    dynamic: ghostty_vt.color.DynamicRGB,
) void {
    const c = dynamic.override orelse return;
    writer.print("\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{
        @backingInt(kind), c.r, c.g, c.b,
    }) catch |err| {
        std.log.warn("failed to format dynamic color err={s}", .{@errorName(err)});
    };
}

fn writeColorOverrides(writer: *std.Io.Writer, term: *const ghostty_vt.Terminal) void {
    const colors = &term.colors;
    writeDynamicColor(writer, .foreground, colors.foreground);
    writeDynamicColor(writer, .background, colors.background);
    writeDynamicColor(writer, .cursor, colors.cursor);
    var it = colors.palette.mask.iterator(.{});
    while (it.next()) |i| {
        const c = colors.palette.current[i];
        writer.print("\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{
            i, c.r, c.g, c.b,
        }) catch |err| {
            std.log.warn("failed to format palette color err={s}", .{@errorName(err)});
        };
    }
}

fn hasCustomTabstops(term: *const ghostty_vt.Terminal) bool {
    for (0..term.cols) |col| {
        // Match Ghostty Tabstops.reset, which excludes the final column.
        const default = col > 0 and col % 8 == 0 and col < term.cols - 1;
        if (term.tabstops.get(col) != default) return true;
    }
    return false;
}

fn writeCursorStyle(writer: *std.Io.Writer, term: *const ghostty_vt.Terminal, screen: *const ghostty_vt.Screen) void {
    // A default cursor must keep the attaching client's configured shape.
    if (term.cursor.is_default) return;
    const steady: u8 = switch (screen.cursor.cursor_style) {
        .block => 2,
        .underline => 4,
        .bar => 6,
        else => return,
    };
    const code = steady - @as(u8, if (term.modes.get(.cursor_blinking)) 1 else 0);
    writer.print("\x1b[{d} q", .{code}) catch |err| {
        std.log.warn("failed to format cursor style err={s}", .{@errorName(err)});
    };
}

fn serializeScreenHistory(screen: *const ghostty_vt.Screen, writer: *std.Io.Writer, client_rows: u16, unwrap: bool) void {
    const pages = &screen.pages;
    const screen_top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    const has_scrollback = !screen_top.eql(active_top);

    // Two-phase serialization to preserve scrollback without corrupting
    // cursor positions. This matters for nested zmx sessions (zmx→SSH→zmx)
    // where the outer daemon's ghostty-vt accumulates inner session scrollback.
    //
    // Phase 1: Emit scrollback content (plain text with styles, no terminal extras).
    // These lines scroll past the visible area into the terminal's scrollback buffer.
    // Phase 2: Clear visible screen, then emit visible content with full extras.
    // The clear ensures visible content starts from a clean slate regardless of
    // how much scrollback preceded it. CUP cursor positioning is then correct.
    //
    // See: https://github.com/neurosnap/zmx/issues/31

    // Phase 1: scrollback only (if any exists)
    if (has_scrollback) {
        if (active_top.up(1)) |sb_bottom_row| {
            var sb_bottom = sb_bottom_row;
            sb_bottom.x = @intCast(pages.cols - 1);

            // Keep history lines logical so they reflow. History only: phase 2's
            // CUP assumes the source row layout. A session with DECAWM off stays
            // hard-wrapped because a receiver reattached without RIS is still in
            // that mode and would truncate an unwrapped line.
            var scroll_fmt = ghostty_vt.formatter.ScreenFormatter.init(screen, .{
                .emit = .vt,
                .unwrap = unwrap,
            });
            scroll_fmt.content = .{
                .selection = ghostty_vt.Selection.init(
                    screen_top,
                    sb_bottom,
                    false,
                ),
            };
            scroll_fmt.extra = .none; // no modes, cursor, keyboard — just content
            scroll_fmt.format(writer) catch |err| {
                std.log.warn("failed to format scrollback err={s}", .{@errorName(err)});
            };
        }

        // The receiver may be taller than the daemon (Watch or follower).
        // Move every replayed row into its history before clearing the screen.
        for (0..client_rows) |_| writer.writeAll("\r\n") catch {};

        // Home the cursor and reset SGR so phase 1 styles don't bleed into
        // phase 2.
        writer.writeAll("\x1b[2J\x1b[H\x1b[0m") catch {};
    }
}

pub fn serializeTerminalState(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, client_rows: u16) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    // Synchronized output (DECSET 2026) is a transient rendering handshake
    // between a program and its current terminal client. Replaying it to a
    // newly attached client can leave that client deferring renders until its
    // local timeout fires, so temporarily exclude it from restored state and
    // restore the original mode on every exit.
    const had_synchronized_output = term.modes.get(.synchronized_output);
    if (had_synchronized_output) {
        term.modes.set(.synchronized_output, false);
    }
    defer if (had_synchronized_output) term.modes.set(.synchronized_output, true);

    // If state contains color override, restore it.
    writeColorOverrides(&builder.writer, term);

    // Leave any receiver alt buffer before restoring history. 1047 avoids a
    // stray 1049 cursor restore; the viewport replay below sets the cursor.
    // A client that died on alt left its primary uncleared. A receiver
    // reattached without RIS can also keep origin mode and margins, which would
    // confine history and shift absolute positions. Phase 2 restores the source's.
    builder.writer.writeAll("\x1b[?1047l\x1b[?6l\x1b[r\x1b[0m\x1b[H\x1b[2J") catch {};
    // A receiver reattached without RIS can still have DECAWM off, which would
    // truncate unwrapped history. When the source has it off, phase 2 sets it.
    if (term.modes.get(.wraparound)) builder.writer.writeAll("\x1b[?7h") catch {};
    const primary = term.screens.get(.primary).?;
    serializeScreenHistory(primary, &builder.writer, client_rows, term.modes.get(.wraparound));

    var format_term = term.*;
    if (term.screens.active_key == .alternate) {
        var primary_fmt = ghostty_vt.formatter.ScreenFormatter.init(primary, .vt);
        primary_fmt.content = .{ .selection = ghostty_vt.Selection.init(
            primary.pages.getTopLeft(.active),
            primary.pages.pin(.{ .active = .{ .x = @intCast(primary.pages.cols - 1), .y = @intCast(primary.pages.rows - 1) } }).?,
            false,
        ) };
        primary_fmt.extra = .all;
        const enters_1049 = term.modes.get(.alt_screen_save_cursor_clear_enter);
        // 1049 saves DECOM with the cursor. Setting it homes the cursor, so do
        // this before the primary formatter positions it.
        const saved_origin = enters_1049 and if (primary.saved_cursor) |saved| saved.origin else false;
        if (saved_origin) builder.writer.writeAll("\x1b[?6h") catch return null;
        primary_fmt.format(&builder.writer) catch return null;
        writeCursorStyle(&builder.writer, term, primary);

        // Mode aliases may coexist. Enter once, while still on primary, so
        // 1049 saves its cursor rather than overwriting it with the alt cursor.
        const mode: u16 = if (enters_1049) 1049 else if (term.modes.get(.alt_screen)) 1047 else 47;
        // The primary's pen, charset, and protection must not reach alt.
        builder.writer.print("\x1b[?{d}h\x1b[0m\x1b(B\x0f\x1b[0\"q\x1b[2J\x1b[H", .{mode}) catch return null;
        // Phase 2 sets the alternate screen's own DECOM.
        if (saved_origin) builder.writer.writeAll("\x1b[?6l") catch return null;
    }
    format_term.modes.set(.alt_screen_legacy, false);
    format_term.modes.set(.alt_screen, false);
    format_term.modes.set(.alt_screen_save_cursor_clear_enter, false);
    const pages = &term.screens.active.pages;

    // Phase 2: visible screen with full extras (modes, cursor, keyboard, etc.)
    var vis_fmt = ghostty_vt.formatter.TerminalFormatter.init(&format_term, .vt);

    // Restrict content to the active viewport only
    const active_tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const active_br = pages.pin(.{
        .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        },
    });

    if (active_tl != null and active_br != null) {
        vis_fmt.content = .{
            .selection = ghostty_vt.Selection.init(
                active_tl.?,
                active_br.?,
                false,
            ),
        };
    }
    // Fallback: if pins are somehow invalid, use null selection (all content)

    vis_fmt.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = hasCustomTabstops(term),
        .pwd = false, // emitted below without the sentinel the formatter includes
        .keyboard = true,
        .screen = .all,
    };

    vis_fmt.format(&builder.writer) catch |err| {
        std.log.warn("failed to format terminal state err={s}", .{@errorName(err)});
        return null;
    };

    writeCursorStyle(&builder.writer, term, term.screens.active);
    writePwd(&builder.writer, term);

    // The formatter has no title extra and never emits OSC 0/1/2, so the title
    // has to be replayed separately or an attaching client shows whatever its
    // terminal defaults to, usually the client process name. OSC 2 does not
    // move the cursor, so this is safe to append after the content.
    if (term.getTitle()) |title| {
        builder.writer.print("\x1b]2;{s}\x07", .{title}) catch |err| {
            std.log.warn("failed to format title err={s}", .{@errorName(err)});
        };
    }

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch |err| {
        std.log.warn("failed to allocate terminal state err={s}", .{@errorName(err)});
        return null;
    };
}

pub fn serializeTerminal(
    alloc: std.mem.Allocator,
    term: *ghostty_vt.Terminal,
    format: HistoryFormat,
) ?[]const u8 {
    return serializeTerminalRange(alloc, term, format, null);
}

/// Formats the active screen and at most `scrollback_rows` preceding physical
/// rows. Null preserves whole-history formatting. Alternate screens have no
/// scrollback, so their selection always stays inside the current grid.
pub fn serializeTerminalRange(
    alloc: std.mem.Allocator,
    term: *ghostty_vt.Terminal,
    format: HistoryFormat,
    scrollback_rows: ?u32,
) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    const opts: ghostty_vt.formatter.Options = switch (format) {
        .plain => .plain,
        .vt => .vt,
        .html => .html,
    };
    var term_formatter = ghostty_vt.formatter.TerminalFormatter.init(term, opts);
    term_formatter.content = .{ .selection = null };
    if (scrollback_rows) |rows| {
        const pages = &term.screens.active.pages;
        const active_top = pages.getTopLeft(.active);
        const top = active_top.up(rows) orelse pages.getTopLeft(.screen);
        const bottom = pages.pin(.{ .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        } }) orelse return null;
        term_formatter.content = .{
            .selection = ghostty_vt.Selection.init(top, bottom, false),
        };
    }
    term_formatter.extra = switch (format) {
        .plain => .none,
        .vt => .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = false,
            .pwd = false, // emitted below without the sentinel the formatter includes
            .keyboard = true,
            .screen = .all,
        },
        .html => .styles,
    };

    term_formatter.format(&builder.writer) catch |err| {
        std.log.warn("failed to format terminal err={s}", .{@errorName(err)});
        return null;
    };

    if (format == .vt) writePwd(&builder.writer, term);

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch |err| {
        std.log.warn("failed to allocate terminal output err={s}", .{@errorName(err)});
        return null;
    };
}

test "serializeTerminalState excludes synchronized output replay" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[?2004h"); // Bracketed paste
    stream.nextSlice("\x1b[?2026h"); // Synchronized output
    stream.nextSlice("hello");

    try testing.expect(term.modes.get(.bracketed_paste));
    try testing.expect(term.modes.get(.synchronized_output));

    const output = serializeTerminalState(alloc, &term, term.screens.active.pages.rows) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    // The serialized output should contain bracketed paste (DECSET 2004)
    // but NOT synchronized output (DECSET 2026)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2004h") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2026h") == null);
}

test "serializeTerminalState restores synchronized output after a failed write" {
    const alloc = testing.allocator;

    var term = try ghostty_vt.Terminal.init(testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("primary\x1b[?1049h\x1b[?2026halt");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try testing.expect(serializeTerminalState(failing.allocator(), &term, 24) == null);
    try testing.expect(term.modes.get(.synchronized_output));
}

test "serializeTerminalState replays the title" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]2;my title\x07");
    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term, term.screens.active.pages.rows) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]2;my title\x07") != null);
}

test "serializeTerminalState omits the title when none is set" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term, term.screens.active.pages.rows) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]2;") == null);
}

test "serializeTerminalState replays the pwd without a NUL sentinel" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]7;file://myhost/private/tmp\x1b\\");
    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term, term.screens.active.pages.rows) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]7;file://myhost/private/tmp\x1b\\") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, output, 0));
}

test "serializeTerminalState omits the pwd when none is set" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term, term.screens.active.pages.rows) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]7;") == null);
}

test "serializeTerminal vt replays the pwd without a NUL sentinel" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]7;file://myhost/private/tmp\x1b\\");
    stream.nextSlice("hello");

    const output = serializeTerminal(alloc, &term, .vt) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]7;file://myhost/private/tmp\x1b\\") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, output, 0));
}

fn testCreateTerminal(alloc: std.mem.Allocator, io: std.Io, cols: u16, rows: u16, vt_data: []const u8) !ghostty_vt.Terminal {
    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_lines = 2_000,
    });
    if (vt_data.len > 0) {
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(vt_data);
    }
    return term;
}

fn expectScreensMatch(alloc: std.mem.Allocator, expected: *ghostty_vt.Terminal, actual: *ghostty_vt.Terminal) !void {
    const exp_str = try expected.plainString(alloc);
    defer alloc.free(exp_str);
    const act_str = try actual.plainString(alloc);
    defer alloc.free(act_str);
    try testing.expectEqualStrings(exp_str, act_str);
}

fn expectCursorAt(term: *ghostty_vt.Terminal, row: usize, col: usize) !void {
    const cursor = &term.screens.active.cursor;
    try testing.expectEqual(col, cursor.x);
    try testing.expectEqual(row, cursor.y);
}

fn serializeRoundtrip(alloc: std.mem.Allocator, io: std.Io, source: *ghostty_vt.Terminal) !ghostty_vt.Terminal {
    const serialized = serializeTerminalState(alloc, source, source.screens.active.pages.rows) orelse
        return error.SerializationFailed;
    defer alloc.free(serialized);

    var dest = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = source.screens.active.pages.cols,
        .rows = source.screens.active.pages.rows,
        .max_scrollback_lines = 2_000,
    });
    var stream = dest.vtStream();
    defer stream.deinit();
    stream.nextSlice(serialized);
    return dest;
}

fn expectMarkerAtRow(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, marker: []const u8, expected_row: usize) !void {
    const plain = try term.plainString(alloc);
    defer alloc.free(plain);
    var row: usize = 0;
    var iter = std.mem.splitScalar(u8, plain, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) != null) {
            try testing.expectEqual(expected_row, row);
            return;
        }
        row += 1;
    }
    std.debug.print("marker '{s}' not found in terminal output\n", .{marker});
    return error.TestExpectedEqual;
}

test "serializeTerminalState roundtrip preserves cursor position" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "\x1b[2J" ++ // clear
        "\x1b[10;20H" // cursor at row 10, col 20 (1-indexed)
    );
    defer term.deinit(alloc);

    try expectCursorAt(&term, 9, 19); // 0-indexed

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectCursorAt(&client, 9, 19);
}

test "serializeTerminalState roundtrip preserves CUP-positioned markers" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[14;50HMARK_D" ++
        "\x1b[16;20H");
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectMarkerAtRow(alloc, &client, "MARK_D", 13);
    try expectCursorAt(&client, 15, 19);
}

test "serializeTerminalState with scrollback preserves visible content" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "");
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    // Generate 80 lines of scrollback (more than 24 visible rows)
    var buf: [32]u8 = undefined;
    for (0..80) |i| {
        const line = std.fmt.bufPrint(&buf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
        stream.nextSlice(line);
    }

    // Clear screen and place markers at specific positions
    stream.nextSlice("\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[16;20H");

    // Verify source terminal has scrollback
    const pages = &term.screens.active.pages;
    const has_scrollback = !pages.getTopLeft(.screen).eql(pages.getTopLeft(.active));
    try testing.expect(has_scrollback);

    // Roundtrip: serialize → feed into fresh terminal
    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    // Visible content must match (this is the core cursor corruption test)
    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectCursorAt(&client, 15, 19);
}

test "serializeTerminalState nested roundtrip preserves content" {
    // Simulates: inner zmx → serialized state → outer ghostty-vt → serialized again → client
    // This is the exact nested session scenario (zmx → SSH → zmx).
    const alloc = testing.allocator;
    const io = testing.io;

    // "Inner" terminal with scrollback + markers
    var inner = try testCreateTerminal(alloc, io, 80, 24, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var buf: [32]u8 = undefined;
        for (0..60) |i| {
            const line = std.fmt.bufPrint(&buf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
            inner_stream.nextSlice(line);
        }
        inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HINNER_A" ++
            "\x1b[12;25HINNER_B" ++
            "\x1b[20;5H");
    }

    // Record inner's ground truth
    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Serialize inner (simulates inner daemon re-attach to inner client)
    const inner_serialized = serializeTerminalState(alloc, &inner, inner.screens.active.pages.rows) orelse
        return error.SerializationFailed;
    defer alloc.free(inner_serialized);

    // "Outer" terminal processes inner's serialized output
    var outer = try testCreateTerminal(alloc, io, 80, 24, "");
    defer outer.deinit(alloc);

    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        outer_stream.nextSlice(inner_serialized);
    }

    // Serialize outer (simulates outer daemon re-attach after detach)
    var client = try serializeRoundtrip(alloc, io, &outer);
    defer client.deinit(alloc);

    // Client must see the same content as inner's visible screen
    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
    try expectMarkerAtRow(alloc, &client, "INNER_A", 2);
    try expectMarkerAtRow(alloc, &client, "INNER_B", 11);
}

test "serializeTerminalState alternate screen not leaked" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "\x1b[?1049h" ++ // enter alt screen
        "\x1b[2J\x1b[3;10HALT_MARK" ++ // write on alt screen
        "\x1b[?1049l" ++ // exit alt screen
        "\x1b[2J\x1b[2;5HMAIN_MARK\x1b[8;20H" // write on main screen
    );
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);

    const plain = try client.plainString(alloc);
    defer alloc.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "ALT_MARK") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "MAIN_MARK") != null);
}

test "serializeTerminalState size mismatch roundtrip" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 30, "\x1b[2J" ++
        "\x1b[3;10HSIZE_A" ++
        "\x1b[12;20HSIZE_B" ++
        "\x1b[20;40HSIZE_C" ++
        "\x1b[15;15H");
    defer term.deinit(alloc);

    // Resize to 24 rows (simulates outer terminal being smaller)
    try term.resize(alloc, ghostty_vt.Terminal.Resize{ .cols = 80, .rows = 24 });

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectCursorAt(&client, term.screens.active.cursor.y, term.screens.active.cursor.x);
}

test "serializeTerminalState scrollback + size mismatch nested roundtrip" {
    const alloc = testing.allocator;
    const io = testing.io;

    var inner = try testCreateTerminal(alloc, io, 80, 30, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var buf: [32]u8 = undefined;
        for (0..80) |i| {
            const line = std.fmt.bufPrint(&buf, "LINE_{d}\r\n", .{i}) catch unreachable;
            inner_stream.nextSlice(line);
        }
        inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HSTRESS_A" ++
            "\x1b[12;25HSTRESS_B" ++
            "\x1b[16;20H");
    }

    // Resize inner to 24 rows (outer terminal is smaller)
    try inner.resize(alloc, ghostty_vt.Terminal.Resize{ .cols = 80, .rows = 24 });

    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Inner serialize → outer processes → outer serialize → client
    const inner_ser = serializeTerminalState(alloc, &inner, inner.screens.active.pages.rows) orelse
        return error.SerializationFailed;
    defer alloc.free(inner_ser);

    var outer = try testCreateTerminal(alloc, io, 80, 24, "");
    defer outer.deinit(alloc);
    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        outer_stream.nextSlice(inner_ser);
    }

    var client = try serializeRoundtrip(alloc, io, &outer);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
}

test "isUserInput: printable characters" {
    // Regular text should be detected as user input
    try testing.expect(isUserInput("hello"));
    try testing.expect(isUserInput("Hello World!"));
    try testing.expect(isUserInput("12345"));
    try testing.expect(isUserInput("!@#$%^&*()"));
}

test "isUserInput: whitespace characters" {
    // Space character is printable
    try testing.expect(isUserInput(" "));
    try testing.expect(isUserInput("   "));
}

test "isUserInput: line feed (LF)" {
    // LF triggers .execute action
    try testing.expect(isUserInput("\n"));
    try testing.expect(isUserInput("test\n"));
}

test "isUserInput: carriage return (CR)" {
    // CR triggers .execute action
    try testing.expect(isUserInput("\r"));
    try testing.expect(isUserInput("test\r"));
}

test "isUserInput: tab" {
    // Tab triggers .execute action
    try testing.expect(isUserInput("\t"));
    try testing.expect(isUserInput("col1\tcol2"));
}

test "isUserInput: backspace" {
    // Backspace triggers .execute action
    try testing.expect(isUserInput("\x08"));
    try testing.expect(isUserInput("test\x08"));
}

test "isUserInput: arrow keys (CSI ~)" {
    // Arrow keys use CSI with ~ - these have params
    try testing.expect(isUserInput("\x1b[3~")); // delete
    try testing.expect(isUserInput("\x1b[5~")); // page up
    try testing.expect(isUserInput("\x1b[6~")); // page down
}

test "isUserInput: modified arrow keys with CSI u" {
    // Modified arrow keys with CSI ... u
    try testing.expect(isUserInput("\x1bOA")); // up with modifier
    try testing.expect(isUserInput("\x1bOB")); // down with modifier
    try testing.expect(isUserInput("\x1bOC")); // right with modifier
    try testing.expect(isUserInput("\x1bOD")); // left with modifier
}

test "isUserInput: up arrow legacy" {
    // Legacy up arrow: CSI A (with params for kitty-style)
    try testing.expect(isUserInput("\x1b[1;1A")); // kitty-style legacy
}

test "isUserInput: up arrow kitty" {
    // Kitty keyboard up arrow: CSI 1;1;1A (no colon format supported by parser)
    try testing.expect(isUserInput("\x1b[1;1;1A")); // kitty up arrow
}

test "isUserInput: arrow keys with modifier params CSI A-D" {
    // Modified arrow keys like Ctrl+Up: CSI 1;5A
    try testing.expect(isUserInput("\x1b[1;5A")); // Ctrl+Up
    try testing.expect(isUserInput("\x1b[1;5B")); // Ctrl+Down
    try testing.expect(isUserInput("\x1b[1;5C")); // Ctrl+Right
    try testing.expect(isUserInput("\x1b[1;5D")); // Ctrl+Left
    try testing.expect(isUserInput("\x1b[1;3A")); // Alt+Up
    try testing.expect(isUserInput("\x1b[1;3B")); // Alt+Down
}

test "isUserInput: CSI arrows exclude intermediate sequences" {
    const finals = "ABCD";
    for (finals) |final| {
        var ordinary = [_]u8{ 0x1b, '[', final };
        var modified = [_]u8{ 0x1b, '[', '1', ';', '5', final };
        var intermediate = [_]u8{ 0x1b, '[', '1', ';', '5', ' ', final };
        try testing.expect(isUserInput(&ordinary));
        try testing.expect(isUserInput(&modified));
        try testing.expect(!isUserInput(&intermediate));
    }
}

test "isUserInput: function keys with modifiers CSI 27 ; ~" {
    // Legacy modified keys: CSI 27 ; ... ~
    try testing.expect(isUserInput("\x1b[15;2~")); // F4 with modifier
    try testing.expect(isUserInput("\x1b[17;2~")); // F5 with modifier
    try testing.expect(isUserInput("\x1b[18;2~")); // F6 with modifier
}

test "isUserInput: enter key" {
    // Enter is LF (0x0A)
    try testing.expect(isUserInput("\x0A"));
}

test "isUserInput: mixed content" {
    // Mix of printable and control sequences
    try testing.expect(isUserInput("hello\nworld"));
    try testing.expect(isUserInput("\x1b[3~\x1b[6~")); // multiple CSI ~ sequences
    try testing.expect(isUserInput("abc\x1b[3~def")); // text with CSI ~
}

test "isUserInput: non-user input (escape sequences only)" {
    // Cursor movement without user input
    try testing.expect(!isUserInput("\x1b[2;1H")); // CSI H cursor home
    // SGR color set (no printing)
    try testing.expect(!isUserInput("\x1b[0m"));
    // Cursor position report query
    try testing.expect(!isUserInput("\x1b[6n"));
}

test "isUserInput: empty string" {
    try testing.expect(!isUserInput(""));
}

test "isUserInput: only whitespace controls" {
    // Multiple control chars should return true
    try testing.expect(isUserInput("\n\r\t"));
}

test "isUserInput: kitty keyboard sequences" {
    // Kitty keyboard protocol uses CSI u
    try testing.expect(isUserInput("\x1b[11;2u")); // F1 with modifier
    try testing.expect(isUserInput("\x1b[12;2u")); // F2 with modifier
    try testing.expect(isUserInput("\x1b[102;1:1u")); // literal "f" press
    try testing.expect(isUserInput("\x1b[57444;1:1u")); // Kitty functional key press
    try testing.expect(!isUserInput("\x1b[102;1:3u")); // literal "f" release only
    try testing.expect(isUserInput("\x1b[102;1:1u\x1b[67;65;31M")); // key press with mouse noise
}

test "isUserInput: mouse events (CSI M) excluded" {
    // Basic mouse tracking (SGR disabled): CSI M Cb Cx Cy
    // Mouse events should NOT trigger leader switch
    try testing.expect(!isUserInput("\x1b[M@ 0 0")); // button 0, pos 0,0
    try testing.expect(!isUserInput("\x1b[M@ 1 1")); // button 1, pos 1,1
}

test "isUserInput: mouse events SGR mode CSI < excluded" {
    // SGR extended mouse tracking: CSI < Cb;Cx;Y M
    // Mouse events should NOT trigger leader switch
    try testing.expect(!isUserInput("\x1b[<0;1;1M")); // button release
    try testing.expect(!isUserInput("\x1b[<64;1;1M")); // button press
}

test "isMouseReport accepts complete reports and rejects partial or mixed input" {
    try testing.expect(isMouseReport("\x1b[<35;116;62M"));
    try testing.expect(isMouseReport("\x1b[M !!"));
    try testing.expect(isMouseReport("\x1b[<64;1;1M\x1b[<65;1;1M"));
    try testing.expect(!isMouseReport(""));
    try testing.expect(!isMouseReport("\x1b[<35;116;62"));
    try testing.expect(!isMouseReport("\x1b[<0;1;1Mtyped"));
}

test "isUserInput: focus events excluded" {
    // Focus in/out are automatic terminal events, not user typing
    try testing.expect(!isUserInput("\x1b[I")); // focus in
    try testing.expect(!isUserInput("\x1b[O")); // focus out
}

test "isUserInput: bracketed paste included" {
    // Bracketed paste start/end are user-initiated paste operations
    try testing.expect(isUserInput("\x1b[200~")); // paste start
    try testing.expect(isUserInput("\x1b[201~")); // paste end
    // Content between start/end is also user input
    try testing.expect(isUserInput("\x1b[200~hello\x1b[201~"));
}

test "serializeTerminalRange screen only returns the active screen" {
    const alloc = testing.allocator;
    var term = try testCreateTerminal(alloc, testing.io, 80, 3, "1\r\n2\r\n3\r\n4\r\n5");
    defer term.deinit(alloc);

    const output = serializeTerminalRange(alloc, &term, .plain, 0) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);
    try testing.expectEqualStrings("3\n4\n5", output);
}

test "serializeTerminalRange adds the requested scrollback rows" {
    const alloc = testing.allocator;
    var term = try testCreateTerminal(alloc, testing.io, 80, 3, "1\r\n2\r\n3\r\n4\r\n5");
    defer term.deinit(alloc);

    const output = serializeTerminalRange(alloc, &term, .plain, 1) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);
    try testing.expectEqualStrings("2\n3\n4\n5", output);

    const all = serializeTerminalRange(alloc, &term, .plain, 100) orelse return error.TestUnexpectedNull;
    defer alloc.free(all);
    const full = serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(full);
    try testing.expectEqualStrings(full, all);
}

test "serializeTerminalRange alternate screen returns only its grid" {
    const alloc = testing.allocator;
    var term = try testCreateTerminal(alloc, testing.io, 80, 3, "1\r\n2\r\n3\r\n4\r\n5\x1b[?1049h\x1b[Halt");
    defer term.deinit(alloc);

    const output = serializeTerminalRange(alloc, &term, .plain, 100) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);
    try testing.expectEqualStrings("alt", output);
}
