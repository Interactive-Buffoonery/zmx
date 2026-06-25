const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");

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

test "cwdForPid returns current process cwd" {
    const alloc = std.testing.allocator;

    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try std.posix.getcwd(&expected_buf);

    const actual = try cwdForPid(alloc, @intCast(std.c.getpid()));
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
