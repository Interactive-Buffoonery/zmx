#!/usr/bin/env python3
"""Socket regressions for #827; kernel geometry is sampled independently of reads."""
import fcntl, hashlib, json, os, signal, struct, subprocess, sys, tempfile, threading, time, tty
from pathlib import Path
from leadership import Client, HEADER, USER, SIZE, TAKE, STATE, DOWN, REPLY, environment, wait, read_receipts
import termios


def frame(tag, data=b''):
    return HEADER.pack(tag, len(data)) + data


def fixture(root):
    tty.setraw(0)
    def monitor():
        while True:
            request = Path(root + '/query')
            if request.exists():
                token = request.read_text()
                size = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)))
                Path(root + '/geometry').write_text(json.dumps([token, list(size)]))
            time.sleep(.005)
    threading.Thread(target=monitor, daemon=True).start()
    with open(root + '/receipts', 'a', buffering=1) as out:
        out.write(json.dumps({'pid': os.getpid(), 'daemon': os.getppid()}) + '\n')
        pending = b''
        while True:
            while Path(root + '/blocked').exists():
                time.sleep(.005)
            pending += os.read(0, 4096)
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                out.write(json.dumps({'bytes': len(line), 'sha256': hashlib.sha256(line).hexdigest()}) + '\n')


def scenario(binary, kind):
    with tempfile.TemporaryDirectory(prefix='zmx-827-regression-') as root:
        env = environment(root)
        clients = []
        def records():
            return read_receipts(root + '/receipts')
        sequence = 0
        def geometry():
            nonlocal sequence
            sequence += 1
            token = str(sequence)
            Path(root + '/query').write_text(token)
            def sample():
                try:
                    data = json.loads(Path(root + '/geometry').read_text())
                    return data[1] if data[0] == token else None
                except (FileNotFoundError, json.JSONDecodeError):
                    return None
            return wait(sample)
        try:
            subprocess.run([binary, 'run', 'regression', '-d', sys.executable, os.path.abspath(__file__), '--fixture', root], env=env, check=True, capture_output=True)
            identity = wait(records)[0]
            a = Client(root + '/regression'); clients.append(a)
            w = Client(root + '/regression'); clients.append(w); w.attach(1)
            if kind == 'history':
                for payload in (b'\xff', b'\x00\x00', b'\x03'):
                    w.send(8, payload)
                    w.state()
                w.send(8); w.receive(8)
            else:
                typed = kind == 'typed-resize'
                if typed:
                    a.attach(2); a.op(TAKE, struct.pack('<HH', 24, 80))
                    wait(lambda: w.state()[0] == a.id)
                    payload = struct.pack('<QQHH', a.id, a.rev, 25, 81) + b'input\n'
                    resize = struct.pack('<QQHH', a.id, a.rev, 37, 97)
                    a.sock.sendall(frame(USER, payload) + frame(SIZE, resize))
                else:
                    a.send(7, struct.pack('<HH', 24, 80)); a.send(0, b'claim\n')
                    wait(lambda: len(records()) == 2)
                    if kind == 'legacy-resize':
                        a.sock.sendall(frame(0, b'input\n') + frame(2, struct.pack('<HH', 37, 97)))
                    elif kind == 'pixels':
                        a.sock.sendall(frame(2, struct.pack('<HH', 37, 97)) + frame(17, struct.pack('<HH', 1234, 567)))
                        wait(lambda: geometry() == [37, 97, 1234, 567])
                        a.send(0, b'pixels\n'); wait(lambda: len(records()) == 3)
                        assert geometry() == [37, 97, 1234, 567]
                    elif kind == 'saturation':
                        Path(root + '/blocked').touch()
                        # Ensure the fixture has returned from its preceding read
                        # before filling the raw PTY; a 128 KiB batch cannot fit.
                        time.sleep(.03)
                        a.send(0, b'X' * 131072 + b'\n')
                        a.sock.sendall(b''.join(frame(2, struct.pack('<HH', 38, 98)) for _ in range(4100)))
                        a.state()  # same-stream barrier proves dispatch survived
                        assert geometry()[:2] == [24, 80], 'resize overtook blocked tail'
                        Path(root + '/blocked').unlink()
                        wait(lambda: len(records()) == 3)
                        assert records()[-1] == {'bytes': 131072, 'sha256': hashlib.sha256(b'X' * 131072).hexdigest()}
                        wait(lambda: geometry()[:2] == [38, 98])
                if kind in ('typed-resize', 'legacy-resize'):
                    wait(lambda: geometry()[:2] == [37, 97])
            # Same attached socket and original child/daemon identities survive.
            a.send(22, b'alive\n')
            wait(lambda: any(r.get('sha256') == hashlib.sha256(b'alive').hexdigest() for r in records()))
            assert records()[0] == identity
            os.kill(identity['pid'], 0); os.kill(identity['daemon'], 0)
            return dict(result='pass', identity=identity, geometry=geometry(), receipts=records())
        finally:
            for client in clients:
                client.close()
            subprocess.run([binary, 'kill', 'regression', '--force'], env=env, capture_output=True)


if __name__ == '__main__':
    if sys.argv[1] == '--fixture':
        fixture(sys.argv[2])
    else:
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        binary = os.path.abspath(sys.argv[1])
        report = {'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(), 'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('src/loop.zig'), Path(__file__), Path('test/leadership.py')]}, 'scenarios': {}}
        for kind in ['history', 'typed-resize', 'legacy-resize', 'pixels', 'saturation']:
            try:
                report['scenarios'][kind] = scenario(binary, kind)
            except Exception as error:
                report['scenarios'][kind] = dict(result='fail', error=repr(error))
        Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        sys.exit(any(r['result'] != 'pass' for r in report['scenarios'].values()))
