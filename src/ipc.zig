const std = @import("std");
const cross = @import("cross.zig");
const socket = @import("socket.zig");
const lib_posix = @import("posix.zig");

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
    Switch = 11,
    Write = 12,
    TaskComplete = 13,
    SessionEnd = 14,
    CwdQuery = 15,
    CwdResponse = 16,
    ResizePixels = 17,
    LabelGet = 18,
    LabelSet = 19,
    LabelClear = 20,
    LabelData = 21,
    Send = 22,
    // Non-exhaustive: this enum comes off the wire via bytesToValue and
    // @enumFromInt, so out-of-range values are representable
    // rather than UB. Switches must handle `_` (unknown tag).
    _,
};

comptime {
    if (@typeInfo(Tag).@"enum".is_exhaustive) @compileError(
        "ipc.Tag must stay non-exhaustive -- old daemons rely on `_` to ignore unknown tags",
    );
}

pub const Header = packed struct {
    tag: Tag,
    len: u32,
};

pub const Resize = packed struct {
    rows: u16,
    cols: u16,
};

pub const ResizePixels = packed struct {
    xpixel: u16,
    ypixel: u16,
};

pub const TerminalSize = packed struct {
    rows: u16,
    cols: u16,
    xpixel: u16,
    ypixel: u16,
};

pub const SessionEndReason = enum(u8) {
    shell_exit = 1,
    detached = 2,
    daemon_died = 3,
    unknown = 4,

    pub fn statusString(self: SessionEndReason) []const u8 {
        return switch (self) {
            .shell_exit => "shell-exit",
            .detached => "detached",
            .daemon_died => "daemon-died",
            .unknown => "unknown",
        };
    }
};

pub const SessionEnd = extern struct {
    reason: SessionEndReason,
    code: i32,

    pub fn init(reason: SessionEndReason, code: i32) SessionEnd {
        var value = std.mem.zeroes(SessionEnd);
        value.reason = reason;
        value.code = code;
        return value;
    }
};

pub const CwdResponse = extern struct {
    path_len: u16,
    overflow: u8,
    path: [MAX_CWD_LEN]u8,

    pub fn empty() CwdResponse {
        return std.mem.zeroes(CwdResponse);
    }

    pub fn fromPath(value: []const u8) CwdResponse {
        var response = std.mem.zeroes(CwdResponse);
        if (value.len > MAX_CWD_LEN) {
            response.overflow = 1;
            return response;
        }
        response.path_len = @intCast(value.len);
        @memcpy(response.path[0..value.len], value);
        return response;
    }

    pub fn pathSlice(self: *const CwdResponse) []const u8 {
        if (self.overflow != 0) return "";
        return self.path[0..self.path_len];
    }
};

pub fn getTerminalSize(fd: i32) TerminalSize {
    var ws: cross.c.struct_winsize = undefined;
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
    }
    return .{ .rows = 24, .cols = 120, .xpixel = 0, .ypixel = 0 };
}

pub const MAX_CMD_LEN = 256;
pub const MAX_CWD_LEN = 256;

/// Frozen wire shape. `daemon_pid` consumes existing tail padding and does
/// not change the 552-byte payload used by already-running daemons.
pub const Info = extern struct {
    clients_len: u64,
    pid: i32,
    cmd_len: u16,
    cwd_len: u16,
    cmd: [MAX_CMD_LEN]u8,
    cwd: [MAX_CWD_LEN]u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
    daemon_pid: i32,
};

pub fn expectedLength(data: []const u8) ?usize {
    if (data.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
    // header.len comes off the wire; widen to usize before adding so a
    // near-u32-max value can't wrap (panic in safe mode, UB in release).
    return @as(usize, @sizeOf(Header)) + @as(usize, header.len);
}

pub fn send(fd: i32, tag: Tag, data: []const u8) !void {
    const header = Header{
        .tag = tag,
        .len = @intCast(data.len),
    };
    const header_bytes = std.mem.asBytes(&header);
    try writeAll(fd, header_bytes);
    if (data.len > 0) {
        try writeAll(fd, data);
    }
}

pub fn appendMessage(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tag: Tag,
    data: []const u8,
) !void {
    const header = Header{
        .tag = tag,
        .len = @intCast(data.len),
    };
    // Guarantee capacity for header + payload in one check to avoid
    // intermediate realloc between the two appends on the hot path.
    try list.ensureTotalCapacity(gpa, list.items.len + @sizeOf(Header) + data.len);
    list.appendSliceAssumeCapacity(std.mem.asBytes(&header));
    if (data.len > 0) {
        list.appendSliceAssumeCapacity(data);
    }
}

pub fn appendTerminalSizeMessages(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tag: Tag,
    size: TerminalSize,
) !void {
    const cells = Resize{ .rows = size.rows, .cols = size.cols };
    const pixels = ResizePixels{ .xpixel = size.xpixel, .ypixel = size.ypixel };
    try appendMessage(alloc, list, tag, std.mem.asBytes(&cells));
    try appendMessage(alloc, list, .ResizePixels, std.mem.asBytes(&pixels));
}

fn writeAll(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try lib_posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

pub const Message = struct {
    tag: Tag,
    data: []u8,

    pub fn deinit(self: Message, alloc: std.mem.Allocator) void {
        if (self.data.len > 0) {
            alloc.free(self.data);
        }
    }
};

pub const SocketMsg = struct {
    header: Header,
    payload: []const u8,
};

pub const SocketBuffer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    head: usize,

    pub fn init(alloc: std.mem.Allocator) !SocketBuffer {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
            .head = 0,
        };
    }

    pub fn deinit(self: *SocketBuffer) void {
        self.buf.deinit(self.alloc);
    }

    /// Reads from fd into buffer.
    /// Returns number of bytes read.
    /// Propagates error.WouldBlock and other errors to caller.
    /// Returns 0 on EOF.
    pub fn read(self: *SocketBuffer, fd: i32) !usize {
        if (self.head > 0) {
            const remaining = self.buf.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.head..]);
                self.buf.items.len = remaining;
            } else {
                self.buf.clearRetainingCapacity();
            }
            self.head = 0;
        }

        var tmp: [4096]u8 = undefined;
        const n = try lib_posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
        }
        return n;
    }

    /// Returns the next complete message or `null` when none available.
    /// `buf` is advanced automatically; caller keeps the returned slices
    /// valid until the following `next()` (or `deinit`).
    pub fn next(self: *SocketBuffer) ?SocketMsg {
        const available = self.buf.items[self.head..];
        const total = expectedLength(available) orelse return null;
        if (available.len < total) return null;

        const hdr = std.mem.bytesToValue(Header, available[0..@sizeOf(Header)]);
        const pay = available[@sizeOf(Header)..total];

        self.head += total;
        return .{ .header = hdr, .payload = pay };
    }
};

const ConnectError = error{
    ConnectionRefused,
    Unexpected,
};

/// Connect-only liveness check. Callers that don't read `Info` should use
/// this (not `probeSession`) so they survive `Info` shape changes.
pub fn connectSession(socket_path: []const u8) ConnectError!i32 {
    return socket.sessionConnect(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => return error.ConnectionRefused,
        else => return error.Unexpected,
    };
}

const SessionProbeError = error{
    Timeout,
    ConnectionRefused,
    Unexpected,
    InfoSizeMismatch,
};

const SessionProbeResult = struct {
    fd: i32,
    info: Info,
    labels: ?[]const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *const SessionProbeResult) void {
        if (self.labels) |lbl| self.alloc.free(lbl);
        lib_posix.close(self.fd);
    }
};

pub fn probeSession(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
) SessionProbeError!SessionProbeResult {
    const timeout_ms = 1000;
    const fd = try connectSession(socket_path);
    errdefer lib_posix.close(fd);

    send(fd, .Info, "") catch return error.Unexpected;
    send(fd, .LabelGet, "") catch {};

    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const poll_result = lib_posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    if (poll_result == 0) {
        return error.Timeout;
    }

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    const n = sb.read(fd) catch return error.Unexpected;
    if (n == 0) return error.Unexpected;

    var info_result: ?Info = null;
    var labels: ?[]const u8 = null;
    errdefer if (labels) |lbl| alloc.free(lbl);

    while (true) {
        if (sb.next()) |msg| {
            if (msg.header.tag == .Info) {
                if (msg.payload.len != @sizeOf(Info)) return error.InfoSizeMismatch;
                info_result = std.mem.bytesToValue(Info, msg.payload[0..@sizeOf(Info)]);
            }
            if (msg.header.tag == .LabelData) {
                labels = alloc.dupe(u8, msg.payload) catch null;
            }

            if (info_result != null and labels != null) break;
            continue;
        }

        // No complete message available, wait for more data
        const more = lib_posix.poll(&poll_fds, 50) catch break;
        if (more == 0) break;
        const n_read = sb.read(fd) catch break;
        if (n_read == 0) break;
    }

    if (info_result) |info| {
        return .{
            .fd = fd,
            .info = info,
            .labels = labels,
            .alloc = alloc,
        };
    }
    return error.Unexpected;
}

//  WIRE PROTOCOL FREEZE: read before "fixing" any test below.
//
//  Changing these constants does not fix the test; it breaks every
//  running daemon for every user until they `pkill -f zmx`.
//
//  Need a new field?   → add a new `Tag` value (next free integer).
//  Need to remove one? → don't. Reserve the integer, stop sending it.
test "Info wire size is frozen" {
    try std.testing.expectEqual(@as(usize, 552), @sizeOf(Info));
    // packed struct{u8,u32} backs to u40 → @sizeOf rounds to 8, not 5.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Header));
}

test "daemon_pid lands in task_exit_code's old tail padding" {
    try std.testing.expectEqual(@as(usize, 548), @offsetOf(Info, "daemon_pid"));
}

test "Init and Resize wire size is frozen" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Resize));
}

test "terminal size messages preserve cell wire shape and pixel extension" {
    const alloc = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    try appendTerminalSizeMessages(alloc, &bytes, .Init, .{
        .rows = 42,
        .cols = 120,
        .xpixel = 1440,
        .ypixel = 900,
    });

    var socket_buf = SocketBuffer{ .buf = bytes, .alloc = alloc, .head = 0 };
    bytes = .empty;
    defer socket_buf.deinit();
    const cells = socket_buf.next() orelse return error.MissingInitMessage;
    try std.testing.expectEqual(Tag.Init, cells.header.tag);
    try std.testing.expectEqual(@as(usize, 4), cells.payload.len);
    try std.testing.expectEqual(Resize{ .rows = 42, .cols = 120 }, std.mem.bytesToValue(Resize, cells.payload));

    const pixels = socket_buf.next() orelse return error.MissingResizePixelsMessage;
    try std.testing.expectEqual(Tag.ResizePixels, pixels.header.tag);
    try std.testing.expectEqual(
        ResizePixels{ .xpixel = 1440, .ypixel = 900 },
        std.mem.bytesToValue(ResizePixels, pixels.payload),
    );
}

test "SessionEnd payload round trips with zeroed padding" {
    const payload = SessionEnd.init(.shell_exit, 7);
    const bytes = std.mem.asBytes(&payload);
    const reason_end = @offsetOf(SessionEnd, "reason") + @sizeOf(SessionEndReason);
    const code_start = @offsetOf(SessionEnd, "code");
    for (bytes[reason_end..code_start]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(SessionEndReason.shell_exit, payload.reason);
    try std.testing.expectEqual(@as(i32, 7), payload.code);
}

test "Tag wire values are frozen" {
    inline for (.{
        .{ Tag.Input, 0 },      .{ Tag.Output, 1 },        .{ Tag.Resize, 2 },
        .{ Tag.Detach, 3 },     .{ Tag.DetachAll, 4 },     .{ Tag.Kill, 5 },
        .{ Tag.Info, 6 },       .{ Tag.Init, 7 },          .{ Tag.History, 8 },
        .{ Tag.Run, 9 },        .{ Tag.Ack, 10 },          .{ Tag.Switch, 11 },
        .{ Tag.Write, 12 },     .{ Tag.TaskComplete, 13 }, .{ Tag.SessionEnd, 14 },
        .{ Tag.CwdQuery, 15 },  .{ Tag.CwdResponse, 16 },  .{ Tag.ResizePixels, 17 },
        .{ Tag.LabelGet, 18 },  .{ Tag.LabelSet, 19 },     .{ Tag.LabelClear, 20 },
        .{ Tag.LabelData, 21 }, .{ Tag.Send, 22 },
    }) |p| try std.testing.expectEqual(@as(u8, p[1]), @intFromEnum(p[0]));
}

pub fn roundTripForTag(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    request_tag: Tag,
    payload: []const u8,
    expected_tag: Tag,
) SessionProbeError![]u8 {
    const fd = try connectSession(socket_path);
    defer lib_posix.close(fd);

    send(fd, request_tag, payload) catch return error.Unexpected;

    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    // One overall ~1s deadline, split into bounded polls so partial messages
    // and interleaved PTY output cannot hide the response indefinitely.
    var polls_remaining: u8 = 20;
    while (polls_remaining > 0) : (polls_remaining -= 1) {
        poll_fds[0].revents = 0;
        const ready = lib_posix.poll(&poll_fds, 50) catch return error.Unexpected;
        if (ready == 0) continue;

        const n = sb.read(fd) catch return error.Unexpected;
        if (n == 0) return error.Unexpected;
        while (sb.next()) |msg| {
            if (msg.header.tag == expected_tag) {
                return alloc.dupe(u8, msg.payload) catch return error.Unexpected;
            }
        }
    }
    return error.Timeout;
}

test "zeroed Info has no stack garbage in wire bytes" {
    var info = std.mem.zeroes(Info);
    info.clients_len = 3;
    info.pid = 999;
    info.task_exit_code = 7;
    const bytes = std.mem.asBytes(&info);
    const task_exit_code_end = @offsetOf(Info, "task_exit_code") + @sizeOf(u8);
    const daemon_pid_start = @offsetOf(Info, "daemon_pid");
    for (bytes[task_exit_code_end..daemon_pid_start]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (bytes[daemon_pid_start..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
