const builtin = @import("builtin");

extern "c" fn amx_proc_parent_pid(pid: c_int) c_int;

pub fn parentPid(pid: i32) ?i32 {
    if (builtin.os.tag != .macos) return null;

    const parent = amx_proc_parent_pid(pid);
    return if (parent > 0) parent else null;
}
