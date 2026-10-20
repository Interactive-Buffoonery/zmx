#!/usr/bin/env python3
"""Real-daemon socket failure model. Run with the freshly built zmx path.

No renderer is impersonated: the fixture records bytes and kernel PTY size.
Native presentation, relay authorization and snapshot boundaries are separate.
"""
import json, os, socket, struct, subprocess, sys, tempfile, time, tty

ATTACH, ACCEPT, STATE, USER, REPLY, TAKE, SIZE, DOWN = range(26, 34)
HEADER = struct.Struct('<BIxxx')

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
        return struct.unpack('<QQHH', self.receive(STATE))
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

def main(binary):
    with tempfile.TemporaryDirectory(prefix='zmx-leadership-') as root:
        env = dict(os.environ, ZMX_DIR=root)
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
            w.op(TAKE, struct.pack('<HH', 50, 150))
            w.op(USER, struct.pack('<HH', 50, 150) + b'forbidden\n')
            for tag in [0, 1, 2, 7, 9, 12, 22, 24, 4, 5]:
                w.send(tag, b'forbidden\n')
            w.send(SIZE, struct.pack('<QQHH', w.id, w.rev, 50, 150))
            assert w.state()[0] == 0 and w.state()[2:] == initial
            a.op(TAKE, struct.pack('<HH', 30, 90))
            wait(lambda: w.state()[0] == a.id)
            assert w.state()[2:] == (30, 90)
            a.close(); clients.remove(a)
            wait(lambda: w.state()[0] == 0)
            assert w.state()[2:] == (30, 90), 'disconnect changed grid'
            a = Client(path); clients.append(a)
            a.attach(2, 60, 160)
            assert w.state()[0] == 0 and w.state()[2:] == (30, 90), 'reattach elected/resized'
            a.op(USER, struct.pack('<HH', 31, 91) + b'A\n')
            b.op(USER, struct.pack('<HH', 41, 101) + b'B\n')
            wait(lambda: len(records()) >= 3)
            got = {r['line']: r['grid'] for r in records() if 'line' in r}
            assert got == {'A': [31, 91], 'B': [41, 101]}, got
            leader, epoch, _, _ = w.state()
            follower = a if leader == b.id else b
            follower.op(REPLY, struct.pack('<Q', epoch) + b'stale\n')
            follower.op(DOWN)
            follower.op(TAKE, struct.pack('<HH', 70, 170))
            assert w.state()[0] == leader
            print(json.dumps({'result': 'pass', 'receipts': records(), 'scope': 'socket leadership; native gaps remain'}))
        finally:
            for c in clients:
                c.close()
            subprocess.run([binary, 'kill', 'leadership', '--force'], env=env, capture_output=True)

if __name__ == '__main__':
    if sys.argv[1] == '--fixture':
        fixture(sys.argv[2])
    else:
        main(os.path.abspath(sys.argv[1]))
