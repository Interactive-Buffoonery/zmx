const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.os.tag == .macos)
    @cImport({
        @cInclude("libproc.h");
    })
else
    struct {};

pub fn parentPid(pid: i32) ?i32 {
    if (builtin.os.tag == .linux) {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        var stat_buffer: [4096]u8 = undefined;
        const length = file.readAll(&stat_buffer) catch return null;
        return linuxParentPid(stat_buffer[0..length]);
    }
    if (builtin.os.tag != .macos) return null;

    var info: c.proc_bsdinfo = undefined;
    const got = c.proc_pidinfo(pid, c.PROC_PIDTBSDINFO, 0, &info, @sizeOf(c.proc_bsdinfo));
    if (got != @sizeOf(c.proc_bsdinfo)) return null;
    return @intCast(info.pbi_ppid);
}

fn linuxParentPid(stat: []const u8) ?i32 {
    const command_end = std.mem.lastIndexOf(u8, stat, ") ") orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[command_end + 2 ..], ' ');
    _ = fields.next() orelse return null; // process state
    return std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch null;
}

test "linux proc stat parent parser handles spaces and parentheses in command" {
    try std.testing.expectEqual(
        @as(?i32, 4242),
        linuxParentPid("9001 (command with ) spaces) S 4242 1 2 3"),
    );
    try std.testing.expectEqual(@as(?i32, null), linuxParentPid("malformed"));
}
