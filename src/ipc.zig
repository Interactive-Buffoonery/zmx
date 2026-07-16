const std = @import("std");
const posix = std.posix;
const cross = @import("cross.zig");
const socket = @import("socket.zig");

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
    ForegroundProcessQuery = 18,
    ForegroundProcessResponse = 19,
    // Non-exhaustive: this enum comes off the wire via bytesToValue and
    // @enumFromInt, so out-of-range values (20-255) are representable
    // rather than UB. Switches must handle `_` (unknown tag).
    _,
};

comptime {
    if (@typeInfo(Tag).@"enum".is_exhaustive) @compileError(
        "ipc.Tag must stay non-exhaustive — old daemons rely on `_` to ignore unknown tags",
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

pub const MAX_EXECUTABLE_LEN = 256;

pub const ForegroundProcessState = enum(u8) {
    foreground = 1,
    no_foreground = 2,
    unavailable = 3,
    _,

    pub fn statusString(self: ForegroundProcessState) []const u8 {
        return switch (self) {
            .foreground => "foreground",
            .no_foreground => "no-foreground",
            .unavailable => "unavailable",
            _ => "unavailable",
        };
    }
};

pub const ForegroundProcessResponse = extern struct {
    daemon_incarnation: u64,
    daemon_created_at: u64,
    transition_sequence: u64,
    sample_sequence: u64,
    daemon_pid: i32,
    state: ForegroundProcessState,
    process_group_id: i32,
    executable_len: u16,
    executable: [MAX_EXECUTABLE_LEN]u8,

    pub fn foreground(process_group_id: i32, executable: []const u8) ForegroundProcessResponse {
        var response = std.mem.zeroes(ForegroundProcessResponse);
        response.state = .foreground;
        response.process_group_id = process_group_id;
        const length = @min(executable.len, MAX_EXECUTABLE_LEN);
        response.executable_len = @intCast(length);
        @memcpy(response.executable[0..length], executable[0..length]);
        return response;
    }

    pub fn noForeground() ForegroundProcessResponse {
        var response = std.mem.zeroes(ForegroundProcessResponse);
        response.state = .no_foreground;
        return response;
    }

    pub fn unavailable() ForegroundProcessResponse {
        var response = std.mem.zeroes(ForegroundProcessResponse);
        response.state = .unavailable;
        return response;
    }

    pub fn executableSlice(self: *const ForegroundProcessResponse) []const u8 {
        return self.executable[0..@min(self.executable_len, MAX_EXECUTABLE_LEN)];
    }

    pub fn sameObservation(
        self: *const ForegroundProcessResponse,
        other: *const ForegroundProcessResponse,
    ) bool {
        return self.state == other.state and
            self.process_group_id == other.process_group_id and
            std.mem.eql(u8, self.executableSlice(), other.executableSlice());
    }

    pub fn isValid(self: *const ForegroundProcessResponse) bool {
        if (self.daemon_pid <= 0 or
            self.daemon_incarnation == 0 or
            self.transition_sequence == 0 or
            self.sample_sequence == 0 or
            self.transition_sequence > self.sample_sequence or
            self.executable_len > MAX_EXECUTABLE_LEN)
        {
            return false;
        }

        return switch (self.state) {
            .foreground => self.process_group_id > 0 and
                self.executable_len > 0 and
                std.unicode.utf8ValidateSlice(self.executableSlice()),
            .no_foreground, .unavailable => self.process_group_id == 0 and self.executable_len == 0,
            _ => false,
        };
    }
};

pub fn getTerminalSize(fd: i32) TerminalSize {
    var ws: cross.c.struct_winsize = undefined;
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{
            .rows = ws.ws_row,
            .cols = ws.ws_col,
            .xpixel = ws.ws_xpixel,
            .ypixel = ws.ws_ypixel,
        };
    }
    return .{ .rows = 24, .cols = 160, .xpixel = 0, .ypixel = 0 };
}

pub const MAX_CMD_LEN = 256;
pub const MAX_CWD_LEN = 256;

/// Frozen wire shape. Do NOT add fields — new stats go in new `Tag` values
/// so old daemons (whose `_` arm ignores unknown tags) stay reachable.
/// Changing `@sizeOf(Info)` breaks `zmx list` against running daemons.
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
    alloc: std.mem.Allocator,
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
    try list.ensureTotalCapacity(alloc, list.items.len + @sizeOf(Header) + data.len);
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
        const n = try posix.write(fd, data[index..]);
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
        const n = try posix.read(fd, &tmp);
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
};

pub fn probeSession(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
) SessionProbeError!SessionProbeResult {
    const fd = try connectSession(socket_path);
    errdefer posix.close(fd);

    return .{
        .fd = fd,
        .info = try requestSessionInfo(alloc, fd, 1000),
    };
}

pub fn requestSessionInfo(
    alloc: std.mem.Allocator,
    fd: i32,
    timeout_ms: u64,
) SessionProbeError!Info {
    var timer = std.time.Timer.start() catch return error.Unexpected;

    send(fd, .Info, "") catch return error.Unexpected;

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    while (true) {
        while (sb.next()) |msg| {
            if (msg.header.tag == .Info) {
                if (msg.payload.len != @sizeOf(Info)) return error.InfoSizeMismatch;
                return std.mem.bytesToValue(Info, msg.payload[0..@sizeOf(Info)]);
            }
        }

        const elapsed_ms = timer.read() / std.time.ns_per_ms;
        if (elapsed_ms >= timeout_ms) return error.Timeout;
        const remaining_ms: i32 = @intCast(@min(timeout_ms - elapsed_ms, std.math.maxInt(i32)));
        var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const poll_result = posix.poll(&poll_fds, remaining_ms) catch return error.Unexpected;
        if (poll_result == 0) return error.Timeout;
        if (poll_fds[0].revents & posix.POLL.IN == 0) return error.Unexpected;

        const n = sb.read(fd) catch return error.Unexpected;
        if (n == 0) return error.Unexpected;
    }
}

//  WIRE PROTOCOL FREEZE — read before "fixing" any test below.
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

test "Init and Resize wire size is frozen" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Resize));
}

test "terminal size messages preserve legacy cells and extend pixels" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    const size = TerminalSize{ .rows = 42, .cols = 120, .xpixel = 1440, .ypixel = 900 };
    try appendTerminalSizeMessages(alloc, &buf, .Init, size);

    var socket_buf = SocketBuffer{
        .buf = buf,
        .alloc = alloc,
        .head = 0,
    };
    buf = .empty;
    defer socket_buf.deinit();

    const init = socket_buf.next() orelse return error.MissingInitMessage;
    try std.testing.expectEqual(Tag.Init, init.header.tag);
    try std.testing.expectEqual(@as(usize, 4), init.payload.len);
    try std.testing.expectEqual(
        Resize{ .rows = 42, .cols = 120 },
        std.mem.bytesToValue(Resize, init.payload),
    );

    const pixels = socket_buf.next() orelse return error.MissingResizePixelsMessage;
    try std.testing.expectEqual(Tag.ResizePixels, pixels.header.tag);
    try std.testing.expectEqual(@as(usize, 4), pixels.payload.len);
    try std.testing.expectEqual(
        ResizePixels{ .xpixel = 1440, .ypixel = 900 },
        std.mem.bytesToValue(ResizePixels, pixels.payload),
    );

    try appendTerminalSizeMessages(alloc, &socket_buf.buf, .Resize, size);
    const resize = socket_buf.next() orelse return error.MissingResizeMessage;
    try std.testing.expectEqual(Tag.Resize, resize.header.tag);
    try std.testing.expectEqual(@as(usize, 4), resize.payload.len);
}

test "Tag wire values are frozen" {
    inline for (.{
        .{ Tag.Input, 0 },                   .{ Tag.Output, 1 },                     .{ Tag.Resize, 2 },
        .{ Tag.Detach, 3 },                  .{ Tag.DetachAll, 4 },                  .{ Tag.Kill, 5 },
        .{ Tag.Info, 6 },                    .{ Tag.Init, 7 },                       .{ Tag.History, 8 },
        .{ Tag.Run, 9 },                     .{ Tag.Ack, 10 },                       .{ Tag.Switch, 11 },
        .{ Tag.Write, 12 },                  .{ Tag.TaskComplete, 13 },              .{ Tag.SessionEnd, 14 },
        .{ Tag.CwdQuery, 15 },               .{ Tag.CwdResponse, 16 },               .{ Tag.ResizePixels, 17 },
        .{ Tag.ForegroundProcessQuery, 18 }, .{ Tag.ForegroundProcessResponse, 19 },
    }) |p| try std.testing.expectEqual(@as(u8, p[1]), @intFromEnum(p[0]));
}

test "foreground process response round trips" {
    try std.testing.expectEqual(@as(usize, 304), @sizeOf(ForegroundProcessResponse));

    var payload = ForegroundProcessResponse.foreground(9001, "ssh");
    payload.daemon_pid = 4242;
    payload.daemon_incarnation = 0x1234;
    payload.daemon_created_at = 1_777_000_111;
    payload.transition_sequence = 2;
    payload.sample_sequence = 7;
    try std.testing.expectEqual(ForegroundProcessState.foreground, payload.state);
    try std.testing.expectEqual(@as(i32, 9001), payload.process_group_id);
    try std.testing.expectEqualStrings("ssh", payload.executableSlice());
    try std.testing.expect(payload.isValid());
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(Tag.ForegroundProcessQuery));
    try std.testing.expectEqual(@as(u8, 19), @intFromEnum(Tag.ForegroundProcessResponse));
}

test "foreground process response rejects malformed state combinations" {
    var missing_identity = ForegroundProcessResponse.foreground(9001, "");
    missing_identity.daemon_pid = 4242;
    missing_identity.daemon_incarnation = 1;
    missing_identity.transition_sequence = 1;
    missing_identity.sample_sequence = 1;
    try std.testing.expect(!missing_identity.isValid());

    var impossible_clear = ForegroundProcessResponse.noForeground();
    impossible_clear.daemon_pid = 4242;
    impossible_clear.daemon_incarnation = 1;
    impossible_clear.transition_sequence = 1;
    impossible_clear.sample_sequence = 1;
    impossible_clear.process_group_id = 9001;
    try std.testing.expect(!impossible_clear.isValid());
}

test "foreground process response requires platform-neutral daemon identity" {
    var response = ForegroundProcessResponse.foreground(9001, "ssh");
    response.daemon_pid = 4242;
    response.daemon_incarnation = 0x1234;
    response.transition_sequence = 1;
    response.sample_sequence = 1;
    try std.testing.expect(response.isValid());

    response.daemon_pid = 0;
    try std.testing.expect(!response.isValid());
    response.daemon_pid = 4242;
    response.daemon_incarnation = 0;
    try std.testing.expect(!response.isValid());
}

test "SessionEnd IPC payload round trips" {
    const alloc = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    const payload = SessionEnd.init(.shell_exit, 0);

    try appendMessage(alloc, &buf, .SessionEnd, std.mem.asBytes(&payload));

    var socket_buf = SocketBuffer{
        .buf = buf,
        .alloc = alloc,
        .head = 0,
    };
    buf = .empty;
    defer socket_buf.deinit();

    const msg = socket_buf.next() orelse return error.MissingSessionEndMessage;
    try std.testing.expectEqual(Tag.SessionEnd, msg.header.tag);
    try std.testing.expectEqual(@sizeOf(SessionEnd), msg.payload.len);

    const decoded = std.mem.bytesToValue(SessionEnd, msg.payload[0..@sizeOf(SessionEnd)]);
    try std.testing.expectEqual(SessionEndReason.shell_exit, decoded.reason);
    try std.testing.expectEqual(@as(i32, 0), decoded.code);
}

test "zeroed SessionEnd has no stack garbage in wire bytes" {
    const payload = SessionEnd.init(.daemon_died, 9);
    const bytes = std.mem.asBytes(&payload);

    const reason_end = @offsetOf(SessionEnd, "reason") + @sizeOf(SessionEndReason);
    const code_start = @offsetOf(SessionEnd, "code");
    for (bytes[reason_end..code_start]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "zeroed Info has no stack garbage in wire bytes" {
    var info = std.mem.zeroes(Info);
    info.clients_len = 3;
    info.pid = 999;
    info.task_exit_code = 7;
    const bytes = std.mem.asBytes(&info);
    // Tail padding after task_exit_code must be zero (asBytes ships it).
    const last_field_end = @offsetOf(Info, "task_exit_code") + @sizeOf(u8);
    for (bytes[last_field_end..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
