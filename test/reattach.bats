#!/usr/bin/env bats
# Re-attach behavior. `zmx attach` needs a tty, so a small python client that
# connects, sends .Init and holds the socket stands in for one here.

load test_helper

# fake_attach <session> <rows> <cols> [hold_seconds]
fake_attach() {
  local session="$1" rows="$2" cols="$3" hold="${4:-0.2}"
  python3 - "$ZMX_DIR" "$session" "$rows" "$cols" "$hold" 3>&- <<'PY'
import os, socket, struct, sys, time
sock_dir, name, rows, cols, hold = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.path.join(sock_dir, name))
payload = struct.pack("<HHHH", rows, cols, 0, 0)            # ipc.Resize
# Current upstream and frozen AMX/legacy cell encodings; each daemon accepts one.
s.sendall(struct.pack("<BIxxx", 7, len(payload)) + payload)
s.sendall(struct.pack("<BIxxx", 7, 4) + payload[:4])
time.sleep(hold)
s.close()
PY
}

# Shell snippet: send DA1 and report whether a reply arrived within $1
# seconds. The result word is assembled by printf so that it only appears in
# history as program output, never as part of the echoed command line.
da1_probe() {
  echo "printf '\033[c'; if IFS= read -r -s -t $1 -d c r; then printf 'DA1_%s\n' ANSWERED; else printf 'DA1_%s\n' TIMEOUT; fi"
}

# reattach_snapshot <session> <rows> <cols>: print the longest run of Z in
# the first Output frame a re-attaching pane receives.
reattach_snapshot() {
  python3 - "$ZMX_DIR" "$1" "$2" "$3" 3>&- <<'PY2'
import os, re, socket, struct, sys
sock_dir, name, rows, cols = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(os.path.join(sock_dir, name))
payload = struct.pack("<HHHH", rows, cols, 0, 0)
s.sendall(struct.pack("<BIxxx", 7, len(payload)) + payload)
s.sendall(struct.pack("<BIxxx", 7, 4) + payload[:4])
buf = b""
while True:
    while len(buf) < 8:
        buf += s.recv(65536)
    tag, size = struct.unpack("<BIxxx", buf[:8])
    while len(buf) < 8 + size:
        buf += s.recv(65536)
    data, buf = buf[8:8 + size], buf[8 + size:]
    if tag == 1:
        print(max((len(m) for m in re.findall(rb"Z+", data)), default=0))
        break
s.close()
PY2
}

count() { "$ZMX" history "$1" | grep -o "$2" | wc -l | tr -d ' '; }

@test "daemon answers DA1 while detached, also after a client has detached" {
  "$ZMX" run test-da -d bash -c "$(da1_probe 5)"
  wait_for_output test-da "DA1_ANSWERED"

  fake_attach test-da 24 80          # attach + detach
  "$ZMX" run test-da bash -c "$(da1_probe 5)"
  for _ in $(seq 60); do [ "$(count test-da DA1_ANSWERED)" -eq 2 ] && break; sleep 0.1; done
  [ "$(count test-da DA1_ANSWERED)" -eq 2 ]
  [ "$(count test-da DA1_TIMEOUT)" -eq 0 ]
}

@test "sole legacy re-attach resizes only when its grid changes" {
  # The trap prints a word assembled at runtime so it can't be confused with
  # the echoed command line in history.
  "$ZMX" run test-winch -d bash -c 'trap "printf \"GOT_%s\n\" WINCH" WINCH; echo READY; while :; do sleep 0.1; done'
  wait_for_output test-winch "READY"

  fake_attach test-winch 24 80       # a leaderless legacy attach recovers leadership
  sleep 0.5
  before=$(count test-winch GOT_WINCH)

  fake_attach test-winch 24 80       # same grid: no synthetic SIGWINCH
  for _ in {1..10}; do
    sleep 0.1
    [ "$(count test-winch GOT_WINCH)" -eq "$before" ]
  done

  fake_attach test-winch 50 140      # new grid: the pane resizes the session
  for _ in $(seq 30); do [ "$(count test-winch GOT_WINCH)" -gt "$before" ] && break; sleep 0.1; done
  [ "$(count test-winch GOT_WINCH)" -gt "$before" ]
}

@test "re-attach snapshot is laid out at the re-attaching pane's grid" {
  "$ZMX" run test-snap -d bash -c 'sleep 0.5; printf "Z%.0s" $(seq 100); echo; sleep 30'
  wait_for_session test-snap
  fake_attach test-snap 24 40 1.5
  run reattach_snapshot test-snap 40 120
  [ "$output" -eq 100 ]
}

@test "attach restores the terminal and preserves signal termination" {
  python3 - "$ZMX" 3>&- <<'PY'
import fcntl, os, pty, select, signal, struct, subprocess, sys, tempfile, termios, time

zmx = sys.argv[1]
restore = b"\x1bc\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\"
with tempfile.TemporaryDirectory(prefix="zmx-signal-", dir="/tmp") as socket_dir:
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZMX_")}
    env.update(ZMX_DIR=socket_dir, SHELL="/bin/sh", TERM="xterm-256color")
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGWINCH, None):
        name = "signal-" + str(sig)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        # Keep the slave open to inspect terminal settings after the client exits.
        proc = subprocess.Popen(
            [zmx, "attach", name, "/bin/sh", "-c", "printf 'READY\\n'; exec cat"],
            stdin=slave, stdout=slave, stderr=slave, env=env,
        )
        output = bytearray()
        try:
            # The client installs signal handlers before it forwards session output.
            deadline = time.monotonic() + 5
            while b"READY" not in output:
                assert time.monotonic() < deadline, (sig, "attach timed out", output)
                if select.select([master], [], [], 0.05)[0]:
                    output.extend(os.read(master, 65536))
            raw = termios.tcgetattr(slave)
            assert not raw[3] & (termios.ECHO | termios.ICANON | termios.ISIG), sig
            assert not raw[1] & termios.OPOST, sig

            if sig is not None:
                os.kill(proc.pid, sig)
            if sig in (None, signal.SIGWINCH):
                os.write(master, b"\x1c")
                expected = 0
            else:
                # Python reports signal termination as a negative signal number.
                expected = -sig
            assert proc.wait(timeout=5) == expected, (sig, proc.returncode)
            assert termios.tcgetattr(slave) == original, sig
            while select.select([master], [], [], 0)[0]:
                output.extend(os.read(master, 65536))
            assert restore in output, sig
            sessions = subprocess.check_output(
                [zmx, "list", "--short"], env=env, text=True, timeout=5,
            )
            assert name in sessions.splitlines(), (sig, sessions)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            subprocess.run(
                [zmx, "kill", name, "--force"],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
            )
            os.close(master)
            os.close(slave)
PY
}
