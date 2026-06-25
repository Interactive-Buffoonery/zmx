const builtin = @import("builtin");

const c = if (builtin.os.tag == .macos)
    @cImport({
        @cInclude("libproc.h");
    })
else
    struct {};

pub fn parentPid(pid: i32) ?i32 {
    if (builtin.os.tag != .macos) return null;

    var info: c.proc_bsdinfo = undefined;
    const got = c.proc_pidinfo(pid, c.PROC_PIDTBSDINFO, 0, &info, @sizeOf(c.proc_bsdinfo));
    if (got != @sizeOf(c.proc_bsdinfo)) return null;
    return @intCast(info.pbi_ppid);
}
