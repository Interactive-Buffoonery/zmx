const std = @import("std");
const lib_posix = @import("posix.zig");

pub var log_system = LogSystem{};

pub fn zmxLogFn(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) void {
    log_system.log(level, scope, format, args) catch {};
}

pub const LogSystem = struct {
    file: ?std.Io.File = null,
    mutex: std.Io.Mutex = .init,
    current_size: u64 = 0,
    max_size: u64 = 2 * 1024 * 1024, // 2MB
    io: std.Io = undefined,

    pub fn init(self: *LogSystem, io: std.Io, path: []const u8, mode: std.Io.File.Permissions) !void {
        self.io = io;

        // The mutex is process-local after daemonization. O_APPEND makes the
        // kernel choose the end offset for every record from every process.
        const fd = try lib_posix.open(path, .{
            .ACCMODE = .WRONLY,
            .APPEND = true,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, mode.toMode());
        const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
        errdefer std.Io.File.close(file, self.io);

        self.current_size = (try std.Io.File.stat(file, self.io)).size;
        self.file = file;
    }

    pub fn deinit(self: *LogSystem) void {
        if (self.file) |f| std.Io.File.close(f, self.io);
    }

    pub fn log(
        self: *LogSystem,
        comptime level: std.log.Level,
        comptime scope: anytype,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.file == null) {
            std.log.defaultLog(level, scope, format, args);
            return;
        }

        if (self.current_size >= self.max_size) {
            self.wipe() catch |err| {
                std.debug.print("Log wipe failed: {s}\n", .{@errorName(err)});
            };
        }

        const now: std.Io.Timestamp = .now(self.io, .real);
        const prefix = "[{d}] [{s}] ({s}): ";
        const scope_name = @tagName(scope);
        const level_name = level.asText();

        const prefix_args = .{
            now.toSeconds(),
            level_name,
            scope_name,
        };

        if (self.file) |f| {
            const record = try std.fmt.allocPrint(
                std.heap.page_allocator,
                prefix ++ format ++ "\n",
                prefix_args ++ args,
            );
            defer std.heap.page_allocator.free(record);

            // Write the complete record in one syscall so another process
            // cannot splice its own record between the prefix and message.
            const written = try lib_posix.write(f.handle, record);
            if (written != record.len) return error.ShortWrite;
            self.current_size += written;
        }
    }

    fn wipe(self: *LogSystem) !void {
        if (self.file) |f| {
            try std.Io.File.setLength(f, self.io, 0);
        }
        self.current_size = 0;
    }
};

test "independent log systems append complete records" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const directory = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(directory);
    const path = try std.fs.path.join(alloc, &.{ directory, "zmx.log" });
    defer alloc.free(path);

    var first = LogSystem{};
    try first.init(io, path, std.Io.File.Permissions.fromMode(0o600));
    defer first.deinit();
    var second = LogSystem{};
    try second.init(io, path, std.Io.File.Permissions.fromMode(0o600));
    defer second.deinit();

    try first.log(.info, .default, "socket path={s}", .{"session-a"});
    try second.log(.info, .default, "socket path={s}", .{"session-b"});

    const contents = try tmp.dir.readFileAlloc(io, "zmx.log", alloc, .limited(4096));
    defer alloc.free(contents);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, contents, 1, "session-a"));
    try std.testing.expect(std.mem.containsAtLeast(u8, contents, 1, "session-b"));
}

test "rotation preserves append behavior across independent handles" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const directory = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(directory);
    const path = try std.fs.path.join(alloc, &.{ directory, "zmx.log" });
    defer alloc.free(path);

    var logs = LogSystem{ .max_size = 1 };
    try logs.init(io, path, std.Io.File.Permissions.fromMode(0o600));
    defer logs.deinit();
    var peer = LogSystem{};
    try peer.init(io, path, std.Io.File.Permissions.fromMode(0o600));
    defer peer.deinit();

    try logs.log(.info, .default, "first", .{});
    try logs.log(.info, .default, "second", .{});
    logs.max_size = std.math.maxInt(u64);
    try peer.log(.info, .default, "peer", .{});
    try logs.log(.info, .default, "third", .{});

    const contents = try tmp.dir.readFileAlloc(io, "zmx.log", alloc, .limited(4096));
    defer alloc.free(contents);
    try std.testing.expect(!std.mem.containsAtLeast(u8, contents, 1, "first"));
    try std.testing.expect(std.mem.containsAtLeast(u8, contents, 1, "second"));
    try std.testing.expect(std.mem.containsAtLeast(u8, contents, 1, "peer"));
    try std.testing.expect(std.mem.containsAtLeast(u8, contents, 1, "third"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, contents, "\n"));
}
