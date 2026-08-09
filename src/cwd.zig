const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");
const cross = @import("cross.zig");
const lib_posix = @import("posix.zig");

extern "c" fn amx_proc_cwd(pid: c_int, buffer: [*]u8, capacity: usize) c_int;
extern "c" fn amx_proc_pgid(pid: c_int) c_int;
extern "c" fn amx_proc_list_pgrp(pgid: c_int, pids: [*]c_int, bytes: c_int) c_int;

pub const CwdResponse = ipc.CwdResponse;

pub fn cwdForPid(alloc: std.mem.Allocator, pid: i32) ![]const u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = amx_proc_cwd(pid, &buffer, buffer.len);
    if (length <= 0) return error.CwdUnavailable;
    return alloc.dupe(u8, buffer[0..@intCast(length)]);
}

/// Resolve the directory represented by the session's active terminal job.
/// Job-control shells make the foreground process group the job the user is
/// interacting with; while no job owns the terminal, that group is the root
/// shell's own. The group's leader can exit while the group keeps the terminal
/// (bash runs pipelines this way), so a dead leader falls back to a surviving
/// group member before the durable root shell.
pub fn cwdForSession(
    alloc: std.mem.Allocator,
    pty_fd: lib_posix.fd_t,
    root_pid: i32,
) ![]const u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    if (pty_fd >= 0) {
        const foreground_pgid = cross.c.tcgetpgrp(pty_fd);
        if (foreground_pgid > 0 and foreground_pgid != root_pid) {
            if (cwdForGroup(alloc, @intCast(foreground_pgid))) |path| {
                return path;
            } else |_| {}
        }
    }

    return cwdForPid(alloc, root_pid);
}

/// Largest foreground process group we probe for a surviving member. A real
/// terminal job is a handful of processes; a group larger than this returns
/// only the first page, which is fine for a best-effort display value.
const max_group_probe = 64;

/// Cwd of the group leader while it lives, else of the first surviving member
/// still in the group. Membership is re-verified via `pbi_pgid` before each
/// lookup so a pid recycled between the terminal query and the libproc call
/// can never contribute an unrelated process's cwd.
fn cwdForGroup(alloc: std.mem.Allocator, pgid: i32) ![]const u8 {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    if (pidInGroup(pgid, pgid)) {
        if (cwdForPid(alloc, pgid)) |path| {
            return path;
        } else |_| {}
    }

    var pids: [max_group_probe]c_int = undefined;
    const bytes = amx_proc_list_pgrp(pgid, &pids, @intCast(@sizeOf(@TypeOf(pids))));
    if (bytes <= 0) return error.CwdUnavailable;
    const count = @min(@as(usize, @intCast(bytes)) / @sizeOf(c_int), pids.len);
    for (pids[0..count]) |pid| {
        if (pid <= 0 or pid == pgid) continue;
        if (!pidInGroup(pid, pgid)) continue;
        if (cwdForPid(alloc, pid)) |path| {
            return path;
        } else |_| {}
    }

    return error.CwdUnavailable;
}

fn pidInGroup(pid: i32, pgid: i32) bool {
    if (builtin.os.tag != .macos) return false;

    return amx_proc_pgid(pid) == pgid;
}

test "cwdForPid returns current process cwd" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_len = try std.process.currentPath(std.testing.io, &expected_buf);
    const expected = expected_buf[0..expected_len];

    const actual = try cwdForPid(alloc, @intCast(std.c.getpid()));
    defer alloc.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "cwdForSession prefers the foreground process group cwd" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    var master_fd: c_int = undefined;
    const child_pid = cross.forkpty(&master_fd, null, null, null);
    if (child_pid < 0) return error.ForkPtyFailed;
    if (child_pid == 0) {
        if (cross.c.chdir(tmp_path.ptr) != 0) lib_posix.exit(2);
        _ = lib_posix.write(lib_posix.STDOUT_FILENO, "R") catch lib_posix.exit(3);
        var release: [1]u8 = undefined;
        _ = lib_posix.read(lib_posix.STDIN_FILENO, &release) catch lib_posix.exit(4);
        lib_posix.exit(0);
    }

    var child_reaped = false;
    defer {
        lib_posix.close(master_fd);
        if (!child_reaped) {
            lib_posix.kill(child_pid, lib_posix.SIG.KILL) catch {};
            _ = lib_posix.waitpid(child_pid, 0);
        }
    }

    var ready: [1]u8 = undefined;
    const n = try lib_posix.read(master_fd, &ready);
    if (n == 0) {
        // EOF instead of the ready byte: the child died before signaling.
        // Surface its exit status rather than a byte-count mismatch.
        const early = lib_posix.waitpid(child_pid, 0);
        child_reaped = true;
        std.debug.print("pty child exited early status={d}\n", .{early.status});
        return error.PtyChildExitedEarly;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'R'), ready[0]);

    const actual = try cwdForSession(
        alloc,
        master_fd,
        @intCast(std.c.getpid()),
    );
    defer alloc.free(actual);
    try std.testing.expectEqualStrings(tmp_path, actual);

    try std.testing.expectEqual(@as(usize, 2), try lib_posix.write(master_fd, "X\n"));
    const result = lib_posix.waitpid(child_pid, 0);
    child_reaped = true;
    try std.testing.expectEqual(@as(u32, 0), result.status & 0x7f);
    try std.testing.expectEqual(@as(u32, 0), (result.status >> 8) & 0xff);
}

test "cwdForSession follows a surviving group member when the leader exits" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    // Recreate the bash-pipeline shape: the session leader (the "shell") stays
    // alive, hands the terminal to a job group, and that group's LEADER exits
    // while another member lives on. tcgetpgrp then names a dead pid.
    var master_fd: c_int = undefined;
    const shell_pid = cross.forkpty(&master_fd, null, null, null);
    if (shell_pid < 0) return error.ForkPtyFailed;
    if (shell_pid == 0) {
        const job_pid = lib_posix.fork() catch lib_posix.exit(2);
        if (job_pid == 0) {
            // Job leader: own group, spawn the surviving member, die.
            if (cross.c.setpgid(0, 0) != 0) lib_posix.exit(3);
            const member_pid = lib_posix.fork() catch lib_posix.exit(4);
            if (member_pid == 0) {
                if (cross.c.chdir(tmp_path.ptr) != 0) lib_posix.exit(5);
                _ = lib_posix.write(lib_posix.STDOUT_FILENO, "R") catch lib_posix.exit(6);
                var release: [1]u8 = undefined;
                _ = lib_posix.read(lib_posix.STDIN_FILENO, &release) catch lib_posix.exit(7);
                lib_posix.exit(0);
            }
            lib_posix.exit(0);
        }
        // Shell: create the job's group (racing the child's setpgid is the
        // standard both-sides pattern), make it the foreground group, reap the
        // job leader, then signal 'D' and idle until killed.
        _ = cross.c.setpgid(job_pid, job_pid);
        if (cross.c.tcsetpgrp(lib_posix.STDIN_FILENO, job_pid) != 0) lib_posix.exit(8);
        _ = lib_posix.waitpid(job_pid, 0);
        _ = lib_posix.write(lib_posix.STDOUT_FILENO, "D") catch lib_posix.exit(9);
        while (true) _ = cross.c.sleep(1);
    }

    defer {
        lib_posix.kill(shell_pid, lib_posix.SIG.KILL) catch {};
        _ = lib_posix.waitpid(shell_pid, 0);
        // Closing the master EOFs the orphaned member's blocking read; launchd
        // reaps it (it was reparented when the job leader died).
        lib_posix.close(master_fd);
    }

    // Proceed only once the member has chdir'd ('R') and the shell has reaped
    // the dead job leader ('D'); the pty may deliver them in either order.
    var saw_ready = false;
    var saw_dead = false;
    while (!saw_ready or !saw_dead) {
        var byte: [1]u8 = undefined;
        const n = try lib_posix.read(master_fd, &byte);
        if (n == 0) return error.PtyChildExitedEarly;
        switch (byte[0]) {
            'R' => saw_ready = true,
            'D' => saw_dead = true,
            else => return error.UnexpectedHandshakeByte,
        }
    }

    const actual = try cwdForSession(alloc, master_fd, shell_pid);
    defer alloc.free(actual);
    try std.testing.expectEqualStrings(tmp_path, actual);
}

test "cwdForSession falls back to the root process cwd" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_len = try std.process.currentPath(std.testing.io, &expected_buf);
    const expected = expected_buf[0..expected_len];

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
