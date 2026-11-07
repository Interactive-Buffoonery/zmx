#!/usr/bin/env python3
"""Socket regressions for #827; kernel geometry is sampled independently of reads."""
import fcntl, hashlib, json, os, signal, struct, subprocess, sys, tempfile, threading, time, tty
from pathlib import Path
from leadership import Client, HEADER, USER, SIZE, TAKE, STATE, DOWN, REPLY, environment, wait, read_receipts
import termios


def frame(tag, data=b''):
    return HEADER.pack(tag, len(data)) + data


def next_frame(client):
    while True:
        if len(client.buf) >= 8:
            tag, size = HEADER.unpack(client.buf[:8])
            if len(client.buf) >= 8 + size:
                data, client.buf = client.buf[8:8 + size], client.buf[8 + size:]
                return tag, data
        chunk = client.sock.recv(65536)
        assert chunk, 'unexpected EOF'
        client.buf += chunk


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
                Path(root + '/blocked-ready').touch()
                time.sleep(.005)
            pending += os.read(0, 4096)
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                out.write(json.dumps({'bytes': len(line), 'sha256': hashlib.sha256(line).hexdigest()}) + '\n')


def cleanup(binary, env, root):
    subprocess.run([binary, 'kill', 'regression', '--force'], env=env, capture_output=True)
    # A deliberately crashing pre-fix daemon cannot clean up its child.
    records = read_receipts(root + '/receipts')
    if records:
        pid = records[0]['pid']
        command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
        if root in command and '--fixture' in command:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


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
            if kind == 'controls':
                # A typed leader keeps each fresh Mac pane a follower, so only the key can claim.
                t = Client(root + '/regression'); clients.append(t); t.attach(2)
                a.send(7, struct.pack('<HH', 24, 80))
                keys = [bytes([c]) for c in range(32) if c not in (10, 27)] + [b'\x7f'] + [b'\x1b[' + bytes([c]) for c in b'ABCDZHF'] + [b'\x1b[1;' + str(modifier).encode() + bytes([final]) for modifier in range(2, 9) for final in b'HF']
                for key in keys:
                    a.close(); clients.remove(a)
                    wait(lambda: w.state()[0] == 0)
                    t.op(TAKE, struct.pack('<HH', 24, 80))
                    wait(lambda: w.state()[0] == t.id)
                    a = Client(root + '/regression'); clients.append(a)
                    a.send(7, struct.pack('<HH', 24, 80))
                    a.send(0, key)
                    try:
                        wait(lambda: w.state()[0] not in (0, t.id))
                    except AssertionError as error:
                        raise AssertionError(('follower key did not claim', key.hex())) from error
                    a.send(22, b'\n')
                wait(lambda: len(records()) == len(keys) + 1)
                assert [r['bytes'] for r in records()[1:]] == [len(k) for k in keys]
                assert [r['sha256'] for r in records()[1:]] == [hashlib.sha256(k).hexdigest() for k in keys]
                assert w.state()[0] != 0
            elif kind == 'watch-effects':
                a.send(7, struct.pack('<HH', 24, 80)); a.send(0, b'claim\n')
                wait(lambda: len(records()) == 2)
                a.state(); w.state()
                a.send(19, b'guard=kept'); a.receive(10)
                w.send(18); labels = w.receive(21)
                w.send(8); history = w.receive(8)
                before = geometry()
                for tag, payload in [(1, b'INJECTED'), (11, b'other'), (19, b'guard=changed'),
                        (20, b''), (24, b'GUARD=changed\n')]:
                    w.send(tag, payload); w.send(STATE)
                    assert next_frame(w)[0] == STATE, ('watch mutation response', tag)
                    w.send(18); assert w.receive(21) == labels, tag
                    w.send(8); assert w.receive(8) == history, tag
                    a.send(STATE)
                    assert next_frame(a)[0] == STATE, ('injected peer output/switch', tag)
                assert geometry() == before and len(records()) == 2
            elif kind == 'same-leader-reply':
                a.attach(2); a.op(TAKE, struct.pack('<HH', 24, 80))
                epoch = wait(lambda: (v if (v := w.state())[0] == a.id else None))[1]
                prefix = struct.pack('<QQ', a.id, a.rev)
                # Changing only the grid retains reply authority under ADR-0036.
                a.sock.sendall(frame(USER, prefix + struct.pack('<HH', 25, 81) + b'user\n') +
                               frame(REPLY, prefix + struct.pack('<Q', epoch) + b'reply\n'))
                wait(lambda: len(records()) == 3)
                assert w.state()[1] == epoch
                assert records()[-1] == {'bytes': 5, 'sha256': hashlib.sha256(b'reply').hexdigest()}
                a.sock.sendall(frame(SIZE, prefix + struct.pack('<HH', 26, 82)) +
                               frame(REPLY, prefix + struct.pack('<Q', epoch) + b'resized-reply\n'))
                wait(lambda: len(records()) == 4)
                assert w.state()[1] == epoch and geometry()[:2] == [26, 82]
                assert records()[-1] == {'bytes': 13, 'sha256': hashlib.sha256(b'resized-reply').hexdigest()}
                a.op(TAKE, struct.pack('<HH', 26, 82))
                wait(lambda: w.state()[1] != epoch)
            elif kind == 'legacy-resize-reply':
                a.send(7, struct.pack('<HH', 24, 80)); a.send(0, b'claim\n')
                wait(lambda: len(records()) == 2)
                epoch = w.state()[1]
                reply = b'\x1b[24;80R\x1b[?62;22c\x1b]11;rgb:0000/0000/0000\x07\x1b'
                a.sock.sendall(frame(2, struct.pack('<HH', 37, 97)) + frame(0, reply))
                a.state()
                a.send(22, b'\n')
                wait(lambda: len(records()) == 3)
                assert records()[-1] == {'bytes': len(reply), 'sha256': hashlib.sha256(reply).hexdigest()}
                assert geometry()[:2] == [37, 97] and w.state()[1] == epoch
            elif kind == 'nonclaiming-replies':
                # A legacy Init recovers a leaderless session, so a typed leader keeps `a` a follower.
                b = Client(root + '/regression'); clients.append(b); b.attach(2)
                b.op(TAKE, struct.pack('<HH', 24, 80))
                wait(lambda: w.state()[0] == b.id)
                a.send(7, struct.pack('<HH', 24, 80))
                replies = [b'\x1b[24;80R', b'\x1b[?62;22c', b'\x1b[>1;4000;0c',
                           b'\x1b]11;rgb:0000/0000/0000\x07', b'\x1b[?2026;2$y', b'\x1b[2;1H']
                for reply in replies:
                    a.send(0, reply); a.state()
                    assert w.state()[0] == b.id, reply.hex()
                a.send(22, b'\n')
                wait(lambda: len(records()) == 2)
                assert records()[-1] == {'bytes': 0, 'sha256': hashlib.sha256(b'').hexdigest()}
            elif kind.startswith('claim-resize-'):
                mode = kind.removeprefix('claim-resize-')
                blocked = mode.startswith('blocked-')
                legacy = mode.endswith('legacy')
                user = mode.endswith('user')
                if legacy:
                    a.send(7, struct.pack('<HH', 24, 80))
                else:
                    a.attach(2)
                b = Client(root + '/regression'); clients.append(b); b.attach(2)
                if mode == 'leaderless-legacy':
                    # With two Mac panes attached, the most recent one is elected
                    # when the leader leaves; the other still claims by typing.
                    p = Client(root + '/regression'); clients.append(p)
                    b.op(TAKE, struct.pack('<HH', 24, 80))
                    wait(lambda: w.state()[0] == b.id)
                    p.send(7, struct.pack('<HH', 26, 82)); p.send(STATE); p.receive(STATE)
                    b.op(DOWN)
                    wait(lambda: w.state()[0] not in (0, b.id) and w.state()[2:] == (26, 82))
                if blocked or mode.startswith('follower-'):
                    b.op(TAKE, struct.pack('<HH', 24, 80))
                    wait(lambda: w.state()[0] == b.id)
                if blocked:
                    Path(root + '/blocked').touch()
                    automation = Client(root + '/regression'); clients.append(automation)
                    automation.send(22, b'block\n')
                    wait(lambda: Path(root + '/blocked-ready').exists())
                    b.op(USER, struct.pack('<HH', 25, 81) + b'P' * 131072 + b'\n')
                    wait(lambda: geometry()[:2] == [25, 81])
                    assert len(records()) == 2
                if legacy:
                    claim = frame(0, b'claim\n')
                    resize = frame(2, struct.pack('<HH', 37, 97))
                else:
                    prefix = struct.pack('<QQ', a.id, a.rev)
                    claim = frame(USER if user else TAKE, prefix + struct.pack('<HH', 24, 80) + (b'claim\n' if user else b''))
                    resize = frame(SIZE, prefix + struct.pack('<HH', 37, 97))
                if mode == 'blocked-intervening':
                    a.sock.sendall(claim); a.state()
                    c = Client(root + '/regression'); clients.append(c); c.attach(2)
                    c.op(TAKE, struct.pack('<HH', 40, 100)); c.state()
                    a.sock.sendall(resize); a.state()
                    expected = [40, 100]
                else:
                    a.sock.sendall(claim + resize); a.state()
                    expected = [37, 97]
                revoked = mode in ('blocked-downgrade', 'blocked-disconnect')
                if mode == 'blocked-downgrade':
                    a.op(DOWN); a.state()
                elif mode == 'blocked-disconnect':
                    a.send(3); a.receive(14)
                    a.close(); clients.remove(a)
                if revoked:
                    expected = [25, 81]
                if blocked:
                    assert geometry()[:2] == [25, 81], 'claim/resize overtook blocked batch'
                    Path(root + '/blocked').unlink()
                    wait(lambda: len(records()) >= 3)
                    assert records()[2] == {'bytes': 131072, 'sha256': hashlib.sha256(b'P' * 131072).hexdigest()}
                wait(lambda: geometry()[:2] == expected)
                leader = w.state()[0]
                assert leader != 0
                if not legacy:
                    assert leader == (b.id if revoked else c.id if mode == 'blocked-intervening' else a.id)
                if legacy or user:
                    wait(lambda: any(r.get('sha256') == hashlib.sha256(b'claim').hexdigest() for r in records()))
            elif kind == 'history':
                for payload in (b'\xff', b'\x00\x00', b'\x03'):
                    w.send(8, payload)
                    w.send(STATE)
                    assert next_frame(w)[0] == STATE, 'malformed History produced a response'
                for payload in (b'', b'\x00', b'\x01', b'\x02'):
                    w.send(8, payload); w.receive(8)
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
                        # A wake line acknowledges that PTY consumption stopped.
                        a.send(22, b'block\n')
                        wait(lambda: Path(root + '/blocked-ready').exists())
                        assert len(records()) == 3
                        a.send(0, b'X' * 131072 + b'\n')
                        a.sock.sendall(b''.join(frame(2, struct.pack('<HH', 38, 98)) for _ in range(4100)))
                        # A distinguishable overflow resize must be rejected, not
                        # merely deferred or accepted by an unbounded queue.
                        a.send(2, struct.pack('<HH', 39, 99))
                        a.state()  # same-stream barrier proves dispatch survived
                        assert geometry()[:2] == [24, 80], 'resize overtook blocked tail'
                        Path(root + '/blocked').unlink()
                        wait(lambda: len(records()) == 4)
                        assert records()[-1] == {'bytes': 131072, 'sha256': hashlib.sha256(b'X' * 131072).hexdigest()}
                        wait(lambda: geometry()[:2] == [38, 98])
                if kind in ('typed-resize', 'legacy-resize'):
                    wait(lambda: geometry()[:2] == [37, 97])
            # Same attached socket and original child/daemon identities survive.
            automation = Client(root + '/regression'); clients.append(automation)
            automation.send(22, b'alive\n')
            wait(lambda: any(r.get('sha256') == hashlib.sha256(b'alive').hexdigest() for r in records()))
            assert records()[0] == identity
            os.kill(identity['pid'], 0); os.kill(identity['daemon'], 0)
            return dict(result='pass', identity=identity, geometry=geometry(), receipts=records())
        finally:
            for client in clients:
                client.close()
            cleanup(binary, env, root)


def pressure(binary):
    with tempfile.TemporaryDirectory(prefix='zmx-827-pressure-') as root:
        env = environment(root)
        clients = []
        def rows():
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
            identity = wait(rows)[0]
            a, b, c, w = [Client(root + '/regression') for _ in range(4)]
            clients += [a, b, c, w]
            for client in (a, b, c):
                client.attach(2)
            w.attach(1)
            a.op(TAKE, struct.pack('<HH', 24, 80))
            wait(lambda: w.state()[0] == a.id)
            Path(root + '/blocked').touch()
            automation = Client(root + '/regression'); clients.append(automation)
            automation.send(22, b'block\n')
            wait(lambda: Path(root + '/blocked-ready').exists())
            a.op(USER, struct.pack('<HH', 25, 81) + b'P' * 131072 + b'\n')
            # Observe unsolicited claim + size, with no Authority request.
            notified = struct.unpack('<QQHH', w.receive(STATE))
            assert notified[0] == a.id and notified[2:] == (25, 81), notified
            wait(lambda: geometry() == [25, 81, 0, 0])
            assert len(rows()) == 2, 'blocked fixture consumed a partial batch'
            prefix = struct.pack('<QQ', b.id, b.rev)
            take = prefix + struct.pack('<HH', 39, 99)
            user = take + b'REVOKED\n'
            b.sock.sendall(frame(TAKE, take) + frame(USER, user) + frame(DOWN, prefix))
            b.state()  # revocation has removed both queued operations
            c.op(TAKE, struct.pack('<HH', 40, 100)); c.state()
            a.op(SIZE, struct.pack('<HH', 37, 97)); a.state()
            assert w.state()[0] == a.id
            assert geometry() == [25, 81, 0, 0], 'takeover overtook blocked batch'
            Path(root + '/blocked').unlink()
            notified = struct.unpack('<QQHH', w.receive(STATE))
            assert notified[0] == c.id and notified[2:] == (40, 100), notified
            wait(lambda: len(rows()) == 3)
            assert rows()[-1] == {'bytes': 131072, 'sha256': hashlib.sha256(b'P' * 131072).hexdigest()}
            wait(lambda: geometry() == [40, 100, 0, 0])
            c.op(USER, struct.pack('<HH', 40, 100) + b'alive\n')
            wait(lambda: len(rows()) == 4)
            assert rows()[-1]['sha256'] == hashlib.sha256(b'alive').hexdigest()
            assert not any(r.get('sha256') == hashlib.sha256(b'REVOKED').hexdigest() for r in rows())
            os.kill(identity['pid'], 0); os.kill(identity['daemon'], 0)
            return dict(result='pass', identity=identity, unsolicited=list(notified), receipts=rows(), kernel_geometry=geometry())
        finally:
            for client in clients:
                client.close()
            cleanup(binary, env, root)


if __name__ == '__main__':
    if sys.argv[1] == '--fixture':
        fixture(sys.argv[2])
    else:
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        binary = os.path.abspath(sys.argv[1])
        report = {'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(), 'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('src/loop.zig'), Path(__file__), Path('test/leadership.py')]}, 'scenarios': {}}
        for kind in ['controls', 'watch-effects', 'same-leader-reply', 'legacy-resize-reply', 'nonclaiming-replies', 'claim-resize-leaderless-legacy', 'claim-resize-follower-legacy', 'claim-resize-leaderless-takeover', 'claim-resize-follower-user', 'claim-resize-blocked-legacy', 'claim-resize-blocked-user', 'claim-resize-blocked-takeover', 'claim-resize-blocked-intervening', 'claim-resize-blocked-downgrade', 'claim-resize-blocked-disconnect', 'history', 'typed-resize', 'legacy-resize', 'pixels', 'saturation', 'pressure']:
            try:
                report['scenarios'][kind] = pressure(binary) if kind == 'pressure' else scenario(binary, kind)
            except Exception as error:
                report['scenarios'][kind] = dict(result='fail', error=repr(error))
        Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        sys.exit(any(r['result'] != 'pass' for r in report['scenarios'].values()))
