#!/usr/bin/env python3
"""Reconnect must preserve a live but temporarily unresponsive daemon.

Run with a built zmx/amx path. Uses only a private socket directory and leaves
its report and logs in the printed fixture directory.
"""
import ctypes
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import signal
import socket
import subprocess
import struct
import sys
import tempfile
import termios
import threading

from leadership import HEADER, environment, wait


def birth(pid):
    if sys.platform == "darwin":
        # proc_bsdinfo from sys/proc_info.h; retain microseconds to detect PID reuse.
        class BSDInfo(ctypes.Structure):
            _fields_ = [("ids", ctypes.c_uint32 * 12), ("comm", ctypes.c_char * 16),
                        ("name", ctypes.c_char * 32), ("job", ctypes.c_uint32 * 6),
                        ("start", ctypes.c_uint64 * 2)]
        info = BSDInfo()
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            return None
        return tuple(info.start)
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except FileNotFoundError:
        return None


def run(binary):
    root = Path(tempfile.mkdtemp(prefix="zmx-reconnect-", dir="/tmp"))
    env = environment(str(root))
    env["TERM"] = "xterm-256color"
    clients, descriptors, identities, status_paths = [], [], set(), []
    stopped = None
    incompatible = None
    births = {}
    report = {"binary": binary, "root": str(root), "checks": []}

    def command(*args):
        return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=8)

    def identity(name="reconnect"):
        output = command("list").stdout
        rows = {}
        for line in output.splitlines():
            fields = dict(re.findall(r"(\w+)=([^\t ]+)", line))
            if fields.get("name") in ("reconnect", "stale", "incompatible"):
                if "daemon_pid" not in fields or "pid" not in fields:
                    continue
                pair = (int(fields["daemon_pid"]), int(fields["pid"]))
                identities.add(pair)
                for pid in pair:
                    births.setdefault(pid, birth(pid))
                rows[fields["name"]] = pair
        return rows.get(name)

    def signal_owned(pid, sig):
        if births.get(pid) is not None and birth(pid) == births[pid]:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass

    def attached(original):
        path = status_paths[-1]
        def event():
            lines = path.read_text().split("\n")[:-1]
            return next((json.loads(line) for line in lines if json.loads(line)["event"] == "attached"), None)
        observed = wait(event)
        assert observed["created"] is False and observed["daemon_pid"] == original[0]

    def attach():
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        descriptors.append(master)
        status = root / ("attach-" + str(len(clients)) + ".jsonl")
        status.touch(mode=0o600)
        status_paths.append(status)
        attach_env = dict(env, AMX_STATUS_FILE=str(status), AMX_STATUS_TOKEN="fixture-token")
        try:
            client = subprocess.Popen(
                [binary, "attach", "reconnect", "/bin/sleep", "120"],
                env=attach_env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            )
        finally:
            os.close(slave)
        clients.append(client)
        return client

    try:
        attach()
        original = wait(identity)
        report["original"] = original
        first_inode = (root / "reconnect").stat().st_ino
        healthy = attach()
        attached(original)
        assert healthy.poll() is None and identity() == original
        report["checks"].append("healthy attach preserves daemon and child")

        stopped = original[0]
        signal_owned(stopped, signal.SIGSTOP)
        attempt = attach()
        wait(lambda: attempt.poll() is not None or (root / "reconnect").stat().st_ino != first_inode, timeout=5)
        assert (root / "reconnect").stat().st_ino == first_inode, "timeout replaced live socket"
        assert attempt.returncode != 0, "failed probe reported success"
        assert not any(json.loads(line)["event"] == "attached" for line in status_paths[-1].read_text().splitlines())
        report["checks"].append("timeout fails without replacing live socket")
        signal_owned(stopped, signal.SIGCONT)
        stopped = None
        resumed = attach()
        attached(original)
        assert resumed.poll() is None and identity() == original
        report["checks"].append("resumed session reconnects with original daemon and child")

        # A listening backend with an incompatible reply is not a stale socket.
        incompatible = socket.socket(socket.AF_UNIX)
        incompatible.bind(str(root / "incompatible"))
        incompatible.listen()
        incompatible.settimeout(3)
        inode = (root / "incompatible").stat().st_ino
        replies, reply_errors = [], []
        def reply():
            try:
                for _ in range(3):
                    with incompatible.accept()[0] as connection:
                        connection.settimeout(1)
                        connection.recv(1024)
                        connection.sendall(HEADER.pack(6, 1) + b"x")
                        replies.append(True)
            except OSError as error:
                reply_errors.append(str(error))
        responder = threading.Thread(target=reply, daemon=True)
        responder.start()
        try:
            rejected = command("run", "incompatible", "-d", "/bin/sleep", "120")
            assert rejected.returncode != 0
            assert (root / "incompatible").stat().st_ino == inode
        finally:
            responder.join(timeout=4)
            incompatible.close()
        assert not responder.is_alive() and len(replies) == 3 and not reply_errors, reply_errors
        report["checks"].append("incompatible live backend is preserved")

        # A socket with no listening process is distinct from an ambiguous timeout.
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(str(root / "stale"))
        stale.close()
        result = command("run", "stale", "-d", "/bin/sleep", "120")
        assert result.returncode == 0, result.stderr
        assert wait(lambda: identity("stale")), "stale socket did not recover a live session"
        report["checks"].append("refused stale socket remains recoverable")
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        cleanup_errors = []
        def cleanup(action):
            try:
                action()
            except Exception as error:
                cleanup_errors.append(str(error))
        if incompatible is not None:
            cleanup(incompatible.close)
        if stopped:
            cleanup(lambda: signal_owned(stopped, signal.SIGCONT))
        # Best-effort discovery must not prevent cleanup of already admitted processes.
        cleanup(identity)
        for pair in identities:
            for pid in pair:
                cleanup(lambda pid=pid: signal_owned(pid, signal.SIGKILL))
        for client in clients:
            cleanup(lambda client=client: client.kill() if client.poll() is None else None)
            cleanup(lambda client=client: client.wait(timeout=3))
        for descriptor in descriptors:
            cleanup(lambda descriptor=descriptor: os.close(descriptor))
        cleanup(lambda: wait(lambda: all(birth(pid) != value for pid, value in births.items())))
        try:
            # The first list removes refused sockets left by direct termination.
            command("list")
            remaining = command("list")
            report["cleanupList"] = remaining.stdout
            assert remaining.returncode == 0 and not remaining.stdout.strip(), "fixture list unavailable or nonempty"
        except Exception as error:
            cleanup_errors.append(str(error))
        report["cleanupErrors"] = cleanup_errors
        report["cleanupPIDs"] = sorted(births)
        if cleanup_errors:
            report["status"] = "failed"
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(root / "report.json", flush=True)
        if cleanup_errors and "error" not in report:
            raise AssertionError(cleanup_errors)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
