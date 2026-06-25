const std = @import("std");
const posix = std.posix;
const cross = @import("cross.zig");

const MAX_STATUS_LINE_LEN = 2048;

pub const StatusConfig = struct {
    path: ?[]const u8,
    token: ?[]const u8,

    pub fn takeFromEnv(alloc: std.mem.Allocator) !StatusConfig {
        const path = if (cross.c.getenv("AMX_STATUS_FILE")) |raw|
            try alloc.dupe(u8, std.mem.span(raw))
        else
            null;
        errdefer if (path) |p| alloc.free(p);

        const token = if (cross.c.getenv("AMX_STATUS_TOKEN")) |raw|
            try alloc.dupe(u8, std.mem.span(raw))
        else
            null;

        _ = cross.c.unsetenv("AMX_STATUS_FILE");
        _ = cross.c.unsetenv("AMX_STATUS_TOKEN");

        return .{ .path = path, .token = token };
    }

    pub fn deinit(self: StatusConfig, alloc: std.mem.Allocator) void {
        if (self.path) |path| alloc.free(path);
        if (self.token) |token| alloc.free(token);
    }
};

pub const StatusFile = struct {
    pub fn emitAttached(
        alloc: std.mem.Allocator,
        cfg: StatusConfig,
        created: bool,
        daemon_pid: i32,
        daemon_created_at: u64,
        session: []const u8,
        ts: i64,
    ) !void {
        const path = cfg.path orelse return;
        const token = cfg.token orelse return;

        var line = std.ArrayList(u8).empty;
        defer line.deinit(alloc);

        try line.appendSlice(alloc, "{\"event\":\"attached\",\"token\":");
        try appendJsonString(alloc, &line, token);
        try line.appendSlice(alloc, ",\"created\":");
        try line.appendSlice(alloc, if (created) "true" else "false");
        try line.writer(alloc).print(
            ",\"daemon_pid\":{d},\"daemon_created_at\":{d},\"session\":",
            .{ daemon_pid, daemon_created_at },
        );
        try appendJsonString(alloc, &line, session);
        try line.writer(alloc).print(",\"ts\":{d}}}\n", .{ts});

        if (line.items.len > MAX_STATUS_LINE_LEN) return error.StatusLineTooLong;

        const fd = try openAppend(path);
        defer posix.close(fd);

        const written = try posix.write(fd, line.items);
        if (written != line.items.len) return error.ShortWrite;
    }

    pub fn emitSessionEnd(
        alloc: std.mem.Allocator,
        cfg: StatusConfig,
        reason: []const u8,
        code: i32,
        session: []const u8,
        ts: i64,
    ) !void {
        const path = cfg.path orelse return;
        const token = cfg.token orelse return;

        var line = std.ArrayList(u8).empty;
        defer line.deinit(alloc);

        try line.appendSlice(alloc, "{\"event\":\"session-end\",\"token\":");
        try appendJsonString(alloc, &line, token);
        try line.appendSlice(alloc, ",\"reason\":");
        try appendJsonString(alloc, &line, reason);
        try line.writer(alloc).print(",\"code\":{d},\"session\":", .{code});
        try appendJsonString(alloc, &line, session);
        try line.writer(alloc).print(",\"ts\":{d}}}\n", .{ts});

        if (line.items.len > MAX_STATUS_LINE_LEN) return error.StatusLineTooLong;

        const fd = try openAppend(path);
        defer posix.close(fd);

        const written = try posix.write(fd, line.items);
        if (written != line.items.len) return error.ShortWrite;
    }

    fn openAppend(path: []const u8) !posix.fd_t {
        const fd = try posix.open(path, .{
            .ACCMODE = .WRONLY,
            .APPEND = true,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0o600);
        errdefer posix.close(fd);

        const st = try posix.fstat(fd);
        if (st.uid != posix.getuid()) return error.InvalidStatusFile;
        if ((st.mode & posix.S.IFMT) != posix.S.IFREG) return error.InvalidStatusFile;
        if ((st.mode & 0o777) != 0o600) return error.InvalidStatusFile;

        return fd;
    }
};

fn appendJsonString(
    alloc: std.mem.Allocator,
    line: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try line.append(alloc, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try line.appendSlice(alloc, "\\\""),
            '\\' => try line.appendSlice(alloc, "\\\\"),
            '\n' => try line.appendSlice(alloc, "\\n"),
            '\r' => try line.appendSlice(alloc, "\\r"),
            '\t' => try line.appendSlice(alloc, "\\t"),
            0x08 => try line.appendSlice(alloc, "\\b"),
            0x0c => try line.appendSlice(alloc, "\\f"),
            else => {
                if (ch < 0x20) {
                    const hex = "0123456789abcdef";
                    try line.appendSlice(alloc, "\\u00");
                    try line.append(alloc, hex[ch >> 4]);
                    try line.append(alloc, hex[ch & 0x0f]);
                } else {
                    try line.append(alloc, ch);
                }
            },
        }
    }
    try line.append(alloc, '"');
}

test "status env is consumed and unset before spawn" {
    const alloc = std.testing.allocator;

    _ = cross.c.setenv("AMX_STATUS_FILE", "/tmp/x", 1);
    _ = cross.c.setenv("AMX_STATUS_TOKEN", "tok", 1);
    defer {
        _ = cross.c.unsetenv("AMX_STATUS_FILE");
        _ = cross.c.unsetenv("AMX_STATUS_TOKEN");
    }

    const cfg = try StatusConfig.takeFromEnv(alloc);
    defer cfg.deinit(alloc);

    try std.testing.expectEqualStrings("/tmp/x", cfg.path.?);
    try std.testing.expectEqualStrings("tok", cfg.token.?);
    try std.testing.expect(cross.c.getenv("AMX_STATUS_FILE") == null);
    try std.testing.expect(cross.c.getenv("AMX_STATUS_TOKEN") == null);
}

test "emitAttached writes one JSON line with incarnation identity" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const path = try std.fs.path.join(alloc, &.{ tmp_path, "status.jsonl" });
    defer alloc.free(path);

    const cfg = StatusConfig{
        .path = path,
        .token = "tok-123",
    };

    try StatusFile.emitAttached(alloc, cfg, true, 4242, 1_777_000_111, "sesh-1", 1_777_000_222);

    const contents = try tmp.dir.readFileAlloc(alloc, "status.jsonl", 4096);
    defer alloc.free(contents);

    try std.testing.expect(std.mem.endsWith(u8, contents, "\n"));
    var lines = std.mem.splitScalar(u8, contents, '\n');
    const line = lines.next() orelse return error.MissingStatusLine;
    try std.testing.expectEqual(@as(usize, 0), (lines.next() orelse "").len);
    try std.testing.expect(lines.next() == null);

    try std.testing.expect(std.mem.indexOf(u8, line, "\"event\":\"attached\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"token\":\"tok-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"created\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"daemon_pid\":4242") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"daemon_created_at\":1777000111") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"session\":\"sesh-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"ts\":1777000222") != null);
}
