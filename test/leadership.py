#!/usr/bin/env python3
"""Real-daemon socket failure model. Run with the freshly built zmx path.

No renderer is impersonated: the fixture records bytes and kernel PTY size.
Native presentation, relay authorization and snapshot boundaries are separate.
"""
import json, os, select, socket, struct, subprocess, sys, tempfile, time, tty, threading, signal, hashlib

ATTACH, ACCEPT, STATE, USER, REPLY, TAKE, SIZE, DOWN = range(26, 34)
HEADER = struct.Struct('<BIxxx')

def environment(root):
    env = {key: value for key, value in os.environ.items() if not key.startswith(('ZMX_', 'AMX_STATUS_'))}
    env.update(ZMX_DIR=root, SHELL='/bin/sh')
    return env

class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(2)
        self.sock.connect(path)
        self.buf = b''
    def send(self, tag, data=b''):
        self.sock.sendall(HEADER.pack(tag, len(data)) + data)
    def receive(self, tag):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if len(self.buf) >= 8:
                kind, size = HEADER.unpack(self.buf[:8])
                if len(self.buf) >= 8 + size:
                    data, self.buf = self.buf[8:8+size], self.buf[8+size:]
                    if kind == tag:
                        return data
                    continue
            chunk = self.sock.recv(65536)
            assert chunk, 'unexpected EOF'
            self.buf += chunk
        raise AssertionError('no acknowledgment')
    def attach(self, role, rows=24, cols=80):
        self.send(ATTACH, struct.pack('<BBHH', 1, role, rows, cols))
        self.id, self.rev = struct.unpack('<QQ', self.receive(ACCEPT))
        return self.state()
    def state(self):
        self.send(STATE)
        latest = self.receive(STATE)
        while select.select([self.sock], [], [], .01)[0]:
            self.buf += self.sock.recv(65536)
        while len(self.buf) >= 8:
            kind, size = HEADER.unpack(self.buf[:8])
            if len(self.buf) < 8 + size:
                break
            data, self.buf = self.buf[8:8+size], self.buf[8+size:]
            if kind == STATE:
                latest = data
        return struct.unpack('<QQHH', latest)
    def op(self, tag, data=b''):
        self.send(tag, struct.pack('<QQ', self.id, self.rev) + data)
    def close(self):
        self.sock.close()

def wait(predicate):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.01)
    raise AssertionError('deadline expired')

def read_receipts(path):
    try:
        with open(path, 'rb') as source:
            # A concurrent read can end inside the last append. Parse only
            # newline-committed records; keep malformed complete records fatal.
            return [json.loads(line) for line in source.read().split(b'\n')[:-1]]
    except FileNotFoundError:
        return []

def fixture(path):
    tty.setraw(0)
    with open(path, 'a', buffering=1) as out:
        out.write(json.dumps({'ready': True}) + '\n')
        data = b''
        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                return
            data += chunk
            while b'\n' in data:
                line, data = data.split(b'\n', 1)
                size = os.get_terminal_size(0)
                out.write(json.dumps({'line': line.decode('ascii'), 'grid': [size.lines, size.columns]}) + '\n')

def query_fixture(path):
    tty.setraw(0)
    os.write(1, b'\x1b[?1004h')
    with open(path, 'a', buffering=1) as out:
        out.write(json.dumps({'ready': True}) + '\n')
        pending = b''
        while True:
            pending += os.read(0, 4096)
            if b'\n' not in pending:
                continue
            line, pending = pending.split(b'\n', 1)
            assert line == b'PROBE', line
            os.write(1, b'\x1b[c')
            response = b''
            deadline = time.monotonic() + 2
            while not response.endswith(b'c') and time.monotonic() < deadline:
                if select.select([0], [], [], .1)[0]:
                    response += os.read(0, 4096)
            out.write(json.dumps({'reply': response.hex()}) + '\n')

def watch_queries(binary, root, env):
    receipts = root + '/query-receipts'
    clients = []
    def rows():
        return read_receipts(receipts)
    try:
        subprocess.run([binary, 'run', 'queries', '-d', sys.executable, os.path.abspath(__file__), '--query-fixture', receipts], env=env, check=True, capture_output=True)
        wait(rows)
        sender = Client(root + '/queries'); clients.append(sender)
        sender.send(22, b'PROBE\n')
        wait(lambda: len(rows()) == 2)
        watcher = Client(root + '/queries'); clients.append(watcher)
        watcher.attach(1)
        sender.send(22, b'PROBE\n')
        wait(lambda: len(rows()) == 3)
        watcher.close(); clients.remove(watcher)
        sender.send(22, b'PROBE\n')
        wait(lambda: len(rows()) == 4)
        replies = [r['reply'] for r in rows() if 'reply' in r]
        assert replies[0] and len(set(replies)) == 1, replies
        return rows()
    finally:
        for client in clients:
            client.close()
        subprocess.run([binary, 'kill', 'queries', '--force'], env=env, capture_output=True)

def old_daemon(binary, root):
    # An old nonexhaustive dispatcher ignores unknown tags. It must never see
    # Init or stdin as a fallback when positive capability acceptance is absent.
    server = socket.socket(socket.AF_UNIX)
    server.bind(root + '/old')
    server.listen()
    received = bytearray()
    def serve():
        conn, _ = server.accept()
        with conn:
            conn.sendall(HEADER.pack(1, 9) + b'untrusted')
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                received.extend(chunk)
    thread = threading.Thread(target=serve)
    thread.start()
    result = subprocess.run([binary, 'watch', 'old'], env=environment(root), capture_output=True, timeout=4)
    thread.join(2)
    server.close()
    assert not thread.is_alive()
    assert result.returncode != 0 and result.stdout == b'', result
    assert len(received) == 14 and HEADER.unpack(received[:8]) == (ATTACH, 6) and received[8:] == struct.pack('<BBHH', 1, 1, 24, 80), received

def main(binary):
    with tempfile.TemporaryDirectory(prefix='zmx-leadership-') as root:
        old_daemon(binary, root)
        env = environment(root)
        query_receipts = watch_queries(binary, root, env)
        path, receipts = root + '/leadership', root + '/receipts'
        clients = []
        def records():
            try:
                return [json.loads(line) for line in open(receipts)]
            except FileNotFoundError:
                return []
        try:
            subprocess.run([binary, 'run', 'leadership', '-d', sys.executable, os.path.abspath(__file__), '--fixture', receipts], env=env, check=True, capture_output=True)
            wait(records)
            a, b, w = [Client(path) for _ in range(3)]
            clients += [a, b, w]
            initial = a.attach(2)[2:]
            assert a.state()[0] == 0, 'attach elected leader'
            b.attach(2, 40, 100)
            w.attach(1)
            b.op(SIZE, struct.pack('<HH', 45, 105))
            assert b.state()[0] == 0 and b.state()[2:] == initial, 'resize elected leader'
            w.send(ATTACH, struct.pack('<BBHH', 1, 2, 50, 150))
            w.op(REPLY, struct.pack('<Q', 1) + b'forbidden\n')
            w.op(TAKE, struct.pack('<HH', 50, 150))
            w.op(USER, struct.pack('<HH', 50, 150) + b'forbidden\n')
            for tag in [0, 1, 2, 7, 9, 11, 12, 17, 19, 20, 22, 24, 4, 5]:
                w.send(tag, b'forbidden\n')
            w.send(SIZE, struct.pack('<QQHH', w.id, w.rev, 50, 150))
            assert w.state()[0] == 0 and w.state()[2:] == initial
            b.op(TAKE, struct.pack('<HH', 0, 80))
            b.op(USER, struct.pack('<HH', 65535, 80) + b'forbidden\n')
            b.send(USER, struct.pack('<QQHH', a.id, a.rev, 50, 150) + b'forbidden\n')
            assert b.state()[0] == 0 and b.state()[2:] == initial, 'invalid claim accepted'
            a.op(TAKE, struct.pack('<HH', 30, 90))
            wait(lambda: w.state()[0] == a.id)
            assert w.state()[2:] == (30, 90)
            old_id = a.id
            a.close(); clients.remove(a)
            wait(lambda: w.state()[0] == 0)
            assert w.state()[2:] == (30, 90), 'disconnect changed grid'
            w.op(TAKE, struct.pack('<HH', 50, 150))
            w.op(USER, struct.pack('<HH', 50, 150) + b'forbidden\n')
            assert w.state()[0] == 0 and w.state()[2:] == (30, 90)
            a = Client(path); clients.append(a)
            a.attach(2, 60, 160)
            assert a.id != old_id, 'reattach reused attachment identity'
            assert w.state()[0] == 0 and w.state()[2:] == (30, 90), 'reattach elected/resized'
            a.op(USER, struct.pack('<HH', 31, 91) + b'A\n')
            wait(lambda: len(records()) >= 2)
            b.op(USER, struct.pack('<HH', 41, 101) + b'B\n')
            wait(lambda: len(records()) >= 3)
            got = {r['line']: r['grid'] for r in records() if 'line' in r}
            assert got == {'A': [31, 91], 'B': [41, 101]}, got
            # Competing sockets: each batch remains contiguous. Kernel size at
            # consumption can already reflect a later batch, so size is proven
            # separately above, not inferred from delayed consumer scheduling.
            a.op(USER, struct.pack('<HH', 31, 91) + b'X' * 32768 + b'\n')
            b.op(USER, struct.pack('<HH', 41, 101) + b'Y' * 32768 + b'\n')
            wait(lambda: len(records()) >= 5)
            assert {r['line'] for r in records()[3:5]} == {'X' * 32768, 'Y' * 32768}
            leader, epoch, _, _ = w.state()
            follower = a if leader == b.id else b
            follower.op(REPLY, struct.pack('<Q', epoch) + b'stale\n')
            # A same-read downgrade must discard a queued unforwarded batch.
            user = struct.pack('<QQHH', follower.id, follower.rev, 32, 92) + b'dropped\n'
            down = struct.pack('<QQ', follower.id, follower.rev)
            follower.sock.sendall(HEADER.pack(USER, len(user)) + user + HEADER.pack(DOWN, len(down)) + down)
            follower.op(TAKE, struct.pack('<HH', 70, 170))
            assert w.state()[0] == leader
            current = a if leader == a.id else b
            _, epoch, _, _ = w.state()
            # A takeover changes epoch before the queued old reply is flushed.
            take = struct.pack('<QQHH', current.id, current.rev, 42, 102)
            reply = struct.pack('<QQQ', current.id, current.rev, epoch) + b'old-reply\n'
            current.sock.sendall(HEADER.pack(TAKE, len(take)) + take + HEADER.pack(REPLY, len(reply)) + reply)
            wait(lambda: w.state()[1] > epoch)
            current.op(USER, struct.pack('<HH', 42, 102) + b'barrier\n')
            wait(lambda: len(records()) >= 6)
            assert records()[-1]['line'] == 'barrier', records()
            assert not any(r.get('line') in {'forbidden', 'stale', 'dropped', 'old-reply'} for r in records())
            current.op(DOWN)
            wait(lambda: w.state()[0] == 0)
            assert w.state()[2:] == (42, 102)
            mac = Client(path); clients.append(mac)
            mac.send(7, struct.pack('<HH', 55, 155))
            mac.send(6)
            mac.receive(6)
            assert w.state()[0] == 0 and w.state()[2:] == (42, 102)
            mac.send(0, b'MAC\n')
            wait(lambda: len(records()) >= 7)
            assert records()[-1] == {'line': 'MAC', 'grid': [55, 155]}
            before = w.state()
            automation = Client(path); clients.append(automation)
            automation.send(22, b'\x03\n')
            wait(lambda: len(records()) >= 8)
            assert records()[-1] == {'line': '\x03', 'grid': [55, 155]}
            assert w.state() == before, 'automation changed authority'
            return {'result': 'pass', 'receipts': [{'line': r.get('line', '')[:80], 'bytes': len(r.get('line', '')), 'sha256': hashlib.sha256(r.get('line', '').encode()).hexdigest(), 'grid': r.get('grid')} for r in records()], 'query_receipts': query_receipts, 'scope': 'socket leadership; native gaps remain'}
        finally:
            for c in clients:
                c.close()
            subprocess.run([binary, 'kill', 'leadership', '--force'], env=env, capture_output=True)

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    if sys.argv[1] == '--query-fixture':
        query_fixture(sys.argv[2])
    elif sys.argv[1] == '--fixture':
        fixture(sys.argv[2])
    else:
        from pathlib import Path
        binary = os.path.abspath(sys.argv[1])
        report = {'binary': binary, 'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(), 'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('src/ipc.zig'), Path('src/loop.zig'), Path('src/main.zig'), Path('src/util.zig'), Path(__file__)]}}
        try:
            report.update(main(binary))
        except BaseException as error:
            report.update(result='fail', error=repr(error))
            raise
        finally:
            encoded = json.dumps(report, indent=2) + '\n'
            if len(sys.argv) > 2:
                Path(sys.argv[2]).write_text(encoded)
            print(encoded)
