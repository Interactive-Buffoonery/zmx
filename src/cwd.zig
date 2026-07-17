const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");
const cross = @import("cross.zig");

const c = if (builtin.os.tag == .macos)
    @cImport({
        @cInclude("libproc.h");
    })
else
    struct {};

pub const CwdResponse = ipc.CwdResponse;

pub fn cwdForPid(alloc: std.mem.Allocator, pid: i32) ![]const u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    var info: c.proc_vnodepathinfo = undefined;
    const got = c.proc_pidinfo(pid, c.PROC_PIDVNODEPATHINFO, 0, &info, @sizeOf(c.proc_vnodepathinfo));
    if (got != @sizeOf(c.proc_vnodepathinfo)) return error.CwdUnavailable;

    const raw = std.mem.sliceTo(info.pvi_cdir.vip_path[0..], 0);
    if (raw.len == 0) return error.CwdUnavailable;
    return alloc.dupe(u8, raw);
}

/// Resolve the directory represented by the session's active terminal job.
/// Job-control shells make the foreground process-group leader the process the
/// user is interacting with; while no job owns the terminal, that leader is the
/// root shell itself. If the foreground process disappears between the terminal
/// query and the libproc lookup, fall back to the durable root shell.
pub fn cwdForSession(
    alloc: std.mem.Allocator,
    pty_fd: std.posix.fd_t,
    root_pid: i32,
) ![]const u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    if (pty_fd >= 0) {
        const foreground_pid = cross.c.tcgetpgrp(pty_fd);
        if (foreground_pid > 0 and foreground_pid != root_pid) {
            if (cwdForPid(alloc, @intCast(foreground_pid))) |path| {
                return path;
            } else |_| {}
        }
    }

    return cwdForPid(alloc, root_pid);
}

test "cwdForPid returns current process cwd" {
    const alloc = std.testing.allocator;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try std.posix.getcwd(&expected_buf);

    const actual = try cwdForPid(alloc, @intCast(std.c.getpid()));
    defer alloc.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "cwdForSession prefers the foreground process group cwd" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    var master_fd: c_int = undefined;
    const child_pid = cross.forkpty(&master_fd, null, null, null);
    if (child_pid < 0) return error.ForkPtyFailed;
    if (child_pid == 0) {
        std.posix.chdir(tmp_path) catch std.posix.exit(2);
        _ = std.posix.write(std.posix.STDOUT_FILENO, "R") catch std.posix.exit(3);
        var release: [1]u8 = undefined;
        _ = std.posix.read(std.posix.STDIN_FILENO, &release) catch std.posix.exit(4);
        std.posix.exit(0);
    }

    var child_reaped = false;
    defer {
        std.posix.close(master_fd);
        if (!child_reaped) {
            std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
            _ = std.posix.waitpid(child_pid, 0);
        }
    }

    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(master_fd, &ready));
    try std.testing.expectEqual(@as(u8, 'R'), ready[0]);

    const actual = try cwdForSession(
        alloc,
        master_fd,
        @intCast(std.c.getpid()),
    );
    defer alloc.free(actual);
    try std.testing.expectEqualStrings(tmp_path, actual);

    try std.testing.expectEqual(@as(usize, 2), try std.posix.write(master_fd, "X\n"));
    const result = std.posix.waitpid(child_pid, 0);
    child_reaped = true;
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(result.status));
}

test "cwdForSession falls back to the root process cwd" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try std.posix.getcwd(&expected_buf);

    const actual = try cwdForSession(
        alloc,
        -1,
        @intCast(std.c.getpid()),
    );
    defer alloc.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "cwd response rejects overflow instead of truncating" {
    var path: [ipc.MAX_CWD_LEN + 1]u8 = undefined;
    @memset(&path, 'a');

    const response = CwdResponse.fromPath(path[0..]);

    try std.testing.expect(response.overflow != 0);
    try std.testing.expectEqual(@as(u16, 0), response.path_len);
}
