#include <libproc.h>
#include <string.h>

int amx_proc_cwd(int pid, char *buffer, unsigned long capacity) {
    struct proc_vnodepathinfo info;
    int got = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (got != (int)sizeof(info)) return 0;

    size_t length = strnlen(info.pvi_cdir.vip_path, sizeof(info.pvi_cdir.vip_path));
    if (length == 0 || length >= capacity) return 0;
    memcpy(buffer, info.pvi_cdir.vip_path, length);
    buffer[length] = '\0';
    return (int)length;
}

int amx_proc_parent_pid(int pid) {
    struct proc_bsdinfo info;
    int got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return got == (int)sizeof(info) ? (int)info.pbi_ppid : 0;
}

int amx_proc_pgid(int pid) {
    struct proc_bsdinfo info;
    int got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return got == (int)sizeof(info) ? (int)info.pbi_pgid : 0;
}

int amx_proc_list_pgrp(int pgid, int *pids, int bytes) {
    return proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, pids, bytes);
}
