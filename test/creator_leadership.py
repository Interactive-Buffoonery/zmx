#!/usr/bin/env python3
"""Fresh non-task socket acceptance, without letting the CLI send Init first."""
import fcntl, hashlib, json, os, signal, struct, subprocess, sys, tempfile, termios, threading, time, tty
from pathlib import Path
from leadership import Client, HEADER, SIZE, USER, REPLY, environment, wait


def fixture(root):
    tty.setraw(0)
    # Give size-only handshakes nonzero kernel pixels to preserve.
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 120, 1200, 480))
    Path(root, 'identity').write_text(json.dumps({'pid': os.getpid(), 'daemon': os.getppid()}))
    def monitor():
        while True:
            sample()
            time.sleep(.005)
    def sample():
        request = Path(root, 'query')
        if request.exists():
            token = request.read_text()
            grid = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)))
            temporary = Path(root, 'geometry.next')
            temporary.write_text(json.dumps([token, grid]))
            temporary.replace(Path(root, 'geometry'))
    threading.Thread(target=monitor, daemon=True).start()
    while True:
        while Path(root, 'blocked').exists():
            Path(root, 'blocked-ready').touch()
            time.sleep(.005)
        import select
        if select.select([0], [], [], .005)[0]:
            data = os.read(0, 65536)
            if not data:
                return
            with open(Path(root, 'bytes'), 'ab', buffering=0) as out:
                out.write(data)


def scenario(binary, kind, typed=False):
    with tempfile.TemporaryDirectory(prefix='zmx-creator-') as root:
        env = environment(root)
        clients, launcher = [], None
        read_fd, write_fd = os.pipe()
        try:
            # A full stdout pipe blocks the CLI's screen-clear write, AFTER
            # daemon creation and BEFORE clientLoop can send its Init. This
            # lets real sockets determine handshake order without timing races.
            os.set_blocking(write_fd, False)
            try:
                while True:
                    os.write(write_fd, bytes(4096))
            except BlockingIOError:
                pass
            os.set_blocking(write_fd, True)
            command = [sys.executable, str(Path(__file__).resolve()), '--fixture', root]
            if kind == 'task':
                subprocess.run([binary, 'run', 'creator', '-d', *command], env=env, check=True, capture_output=True)
            else:
                launcher = subprocess.Popen([binary, 'attach', 'creator', *command], env=env,
                                            stdin=subprocess.PIPE, stdout=write_fd, stderr=subprocess.DEVNULL)
            wait(lambda: Path(root, 'identity').exists())
            sequence = 0
            def geometry():
                nonlocal sequence
                sequence += 1
                token = str(sequence)
                Path(root, 'query').write_text(token)
                def sample():
                    try:
                        value = json.loads(Path(root, 'geometry').read_text())
                        return value[1] if value[0] == token else None
                    except (FileNotFoundError, json.JSONDecodeError):
                        return None
                return wait(sample)
            def received():
                path = Path(root, 'bytes')
                return path.read_bytes() if path.exists() else b''
            def client():
                value = Client(root + '/creator'); clients.append(value)
                return value
            initial = geometry()
            automation_bytes = b''
            watcher = client()
            if kind == 'watch-first':
                watcher.attach(1, 61, 161)
                assert watcher.state()[0] == 0 and geometry() == initial
                # A malformed terminal handshake must not consume creation.
                invalid = client(); invalid.send(7, struct.pack('<HH', 0, 80)); invalid.state()
            if kind.startswith('automation-') or kind == 'run-before-creator':
                automation = client()
                before = watcher.state()
                tag = {'automation-send': 22, 'automation-output': 1,
                       'automation-write': 12, 'run-before-creator': 9}[kind]
                if kind == 'automation-write':
                    path = os.fsencode(Path(root, 'written'))
                    automation.send(tag, struct.pack('<I', len(path)) + path)
                    automation.receive(10)
                    automation_bytes = b"printf '%s' '' | base64 -d > '" + path + b"'\r"
                    wait(lambda: received() == automation_bytes)
                else:
                    automation.send(tag)
                assert watcher.state() == before, ('automation claimed', kind)
                assert geometry() == initial, ('automation resized', kind)
                # Init remains compatible, but cannot restore creation eligibility.
                for attempt in range(2):
                    automation.send(7, struct.pack('<HH', 60, 160))
                    automation.send(2, struct.pack('<HH', 60, 160))
                    assert automation.state() == before, ('automation Init claimed', kind, attempt)
                    assert geometry() == initial, ('automation Init resized', kind, attempt)
            if kind in ('saturated', 'ordered'):
                automation = client()
                Path(root, 'blocked').touch()
                wait(lambda: Path(root, 'blocked-ready').exists())
                # A partial automation batch holds the ordered queue's head.
                automation_bytes = b'X' * 131072
                automation.send(22, automation_bytes)
                count = 4095 if kind == 'saturated' else 3
                automation.sock.sendall((HEADER.pack(22, 1) + b'q') * count)
                automation_bytes += b'q' * count
                automation.state()  # all preceding frames have been dispatched
                before = watcher.state()
                assert before[0] == 0 and geometry() == initial
                if kind == 'saturated':
                    # Rejection must be explicit, with no partial creation claim.
                    rejected = client()
                    if typed:
                        rejected.send(26, struct.pack('<BBHH', 1, 2, 24, 80))
                    else:
                        rejected.send(7, struct.pack('<HH', 24, 80))
                    assert rejected.sock.recv(65536) == b'', 'full-queue handshake was accepted'
                    assert watcher.state() == before, 'rejected handshake consumed creation'
                    assert geometry() == initial, 'rejected handshake resized'
                    rejected.close(); clients.remove(rejected)
                    Path(root, 'blocked').unlink()
                    wait(lambda: received() == automation_bytes)
            creator = client()
            if typed:
                creator.attach(2)
            else:
                creator.send(7, struct.pack('<HH', 24, 80))
            state = creator.state()
            if kind != 'watch-first':
                watcher.attach(1)
            if kind in ('task', 'run-before-creator'):
                assert state[0] == 0, ('task attach claimed', state)
                (creator.op(SIZE, struct.pack('<HH', 37, 97)) if typed else creator.send(2, struct.pack('<HH', 37, 97))); creator.state()
                assert geometry() == initial, 'task attach resized'
            else:
                assert state[0] != 0, ('creator did not lead', state)
                if typed:
                    assert state[0] == creator.id, state
                epoch = state[1]
                assert initial[:2] != [24, 80], 'fixture must differ from handshake'
                if kind == 'ordered':
                    assert geometry() == initial, 'handshake resize overtook automation'
                    Path(root, 'blocked').unlink()
                    wait(lambda: received() == automation_bytes)
                # No explicit Resize/RequestedSize or input precedes this oracle.
                wait(lambda: geometry() == [24, 80, *initial[2:]])
                state = creator.state()
                assert state[2:] == (24, 80), ('handshake authority grid', state)
                if kind.startswith('automation-') or kind in ('ordered', 'saturated'):
                    assert state[1] == before[1] + 1, ('creator epoch', state, before)
                assert received() == automation_bytes, 'handshake injected input'
                if kind in ('settle', 'replies', 'reattach', 'watch-first'):
                    # Coalesced cells + pixels must use the existing ordered path.
                    if typed:
                        creator.op(SIZE, struct.pack('<HH', 37, 97))
                    else:
                        creator.sock.sendall(HEADER.pack(2, 4) + struct.pack('<HH', 37, 97) +
                                             HEADER.pack(17, 4) + struct.pack('<HH', 970, 740))
                    settled = [37, 97, *initial[2:]] if typed else [37, 97, 970, 740]
                    wait(lambda: geometry() == settled)
                    assert watcher.state()[1] == epoch
                if kind == 'replies':
                    pieces = [b'\x1b[12;5R', b'\x1b]11;rgb:0000/0000/0000\x07', b'\x1b']
                    expected = b''
                    for piece in pieces:
                        if typed:
                            creator.op(REPLY, struct.pack('<Q', epoch) + piece)
                        else:
                            creator.send(0, piece)
                        expected += piece
                        wait(lambda: received() == expected)
                        assert watcher.state()[1] == epoch
                elif kind == 'yields':
                    second = client(); second.attach(2, 41, 101)
                    second.op(USER, struct.pack('<HH', 41, 101) + b'other')
                    wait(lambda: received() == b'other')
                    assert watcher.state()[0] == second.id and geometry()[:2] == [41, 101]
                    (creator.op(SIZE, struct.pack('<HH', 60, 160)) if typed else creator.send(2, struct.pack('<HH', 60, 160))); creator.state()
                    assert geometry()[:2] == [41, 101], 'former creator resized after yielding'
                elif kind == 'reattach':
                    creator.close(); clients.remove(creator)
                    wait(lambda: watcher.state()[0] == 0)
                    for role in ('legacy', 'typed'):
                        replacement = client()
                        if role == 'legacy':
                            replacement.send(7, struct.pack('<HH', 60, 160))
                        else:
                            replacement.attach(2, 60, 160)
                        assert replacement.state()[0] == 0, 'reattach claimed'
                        assert geometry() == settled, 'reattach resized'
            if kind.startswith('automation-'):
                # The converted legacy terminal can still claim through real input.
                automation.send(0, b'normal-user')
                wait(lambda: received() == automation_bytes + b'normal-user')
                assert watcher.state()[0] != state[0], 'converted user input did not claim'
                assert geometry()[:2] == [60, 160], 'converted user input lost requested grid'
            data = received()
            return {'scenario': kind, 'typed': typed, 'result': 'pass', 'initial': initial,
                    'final': geometry(), 'authority': watcher.state(), 'bytes_hex': data.hex(),
                    'bytes_sha256': hashlib.sha256(data).hexdigest()}
        finally:
            for value in clients:
                value.close()
            if launcher:
                launcher.terminate()
                try:
                    launcher.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    launcher.kill(); launcher.wait(timeout=3)
                launcher.stdin.close()
            subprocess.run([binary, 'kill', 'creator', '--force'], env=env, capture_output=True, timeout=5)
            os.close(write_fd); os.close(read_fd)


def scenarios(binary):
    results = []
    for kind in ('settle', 'replies', 'yields', 'reattach', 'task', 'watch-first',
                 'automation-send', 'automation-output', 'automation-write', 'run-before-creator',
                 'saturated', 'ordered'):
        for typed in (False, True):
            try:
                results.append(scenario(binary, kind, typed))
            except Exception as error:
                results.append({'scenario': kind, 'typed': typed, 'result': 'fail', 'error': repr(error)})
    return results


if __name__ == '__main__':
    if sys.argv[1] == '--fixture':
        fixture(sys.argv[2])
    else:
        results = scenarios(os.path.abspath(sys.argv[1]))
        Path(sys.argv[2]).write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps(results, indent=2))
        sys.exit(any(row['result'] != 'pass' for row in results))
