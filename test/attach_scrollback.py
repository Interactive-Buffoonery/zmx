#!/usr/bin/env python3
"""Real-daemon attach -> fresh Ghostty terminal; compare ordered rows.

zig build test-replay && python3 test/attach_scrollback.py zig-out/bin/zmx
"""
import os
import fcntl
import pty
import select
import termios
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time
import tty

HEADER = struct.Struct('<BIxxx')


class Client:
    def __init__(self, root, name):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(4)
        self.sock.connect(root + '/' + name)

    def send(self, tag, payload=b''):
        self.sock.sendall(HEADER.pack(tag, len(payload)) + payload)

    def receive(self, wanted):
        def exact(n):
            data = b''
            while len(data) < n:
                chunk = self.sock.recv(n - len(data))
                assert chunk, 'unexpected EOF'
                data += chunk
            return data
        while True:
            tag, n = HEADER.unpack(exact(8))
            data = exact(n)
            if tag == wanted:
                return data

    def attach(self, role, rows, cols):
        if role == 'legacy':
            self.send(7, struct.pack('<HH', rows, cols))
        else:
            self.send(26, struct.pack('<BBHH', 1, role, rows, cols))
            self.receive(27)
        return self.receive(1)

    def close(self):
        self.sock.close()


def fixture(payload):
    tty.setraw(0)
    os.write(1, b'READY')
    os.read(0, 1)
    os.write(1, Path(payload).read_bytes())
    while os.read(0, 1024):
        pass


def main(binary):
    root = subprocess.check_output(['mktemp', '-d', '/tmp/zsp.XXXXXX'], text=True).strip()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ZMX_', 'AMX_STATUS_'))}
    env.update(ZMX_DIR=root, SHELL='/bin/sh')
    replay_bin = str(Path(__file__).resolve().parents[1] / 'zig-out/bin/terminal-replay')
    clients = []
    failures = 0
    total = 0

    def replay(data, rows, cols, width=None):
        Path(root + '/bytes').write_bytes(data)
        cmd = [replay_bin, root + '/bytes', str(rows), str(cols), root + '/text']
        if width:
            cmd.append(str(width))
        subprocess.run(cmd, check=True)
        return [line.rstrip() for line in Path(root + '/text').read_text().splitlines()]

    def start(name, payload, rows, cols):
        Path(root + '/payload').write_bytes(b'\x1bc' + payload)
        subprocess.run([binary, 'run', name, '-d', sys.executable, str(Path(__file__).resolve()), '--fixture', root + '/payload'], env=env, check=True, capture_output=True)
        for _ in range(400):
            out = subprocess.run([binary, 'history', name], env=env, capture_output=True).stdout
            if b'READY' in out:
                break
            time.sleep(.01)
        else:
            raise AssertionError('fixture not ready')
        leader = Client(root, name)
        clients.append(leader)
        leader.send(7, struct.pack('<HH', rows, cols))
        leader.send(22, b'g')
        collected = b''
        while b'END' not in collected:
            collected += leader.receive(1)
        # A history request on the same socket is a daemon processing barrier.
        leader.send(8)
        leader.receive(8)
        return leader

    def check(label, actual, expected):
        nonlocal failures, total
        total += 1
        ok = actual == expected
        failures += not ok
        mismatch = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b), min(len(actual), len(expected)))
        print(f'{"PASS" if ok else "FAIL"} {label}: got={len(actual)} expected={len(expected)} first_mismatch={mismatch}', flush=True)

    try:
        expected = [str(i) for i in range(1, 501)] + ['END']
        payload = ('\r\n'.join(expected)).encode()
        start('numbers', payload, 24, 80)
        for role, rows, cols in [('legacy', 24, 80), (1, 52, 80), (1, 52, 45), ('legacy', 40, 80), (2, 40, 80), (1, 12, 80)]:
            c = Client(root, 'numbers')
            try:
                data = c.attach(role, rows, cols)
            finally:
                c.close()
            lines = replay(data, rows, cols)
            check(f'numbers {role} {rows}x{cols}', [s for s in lines if s], expected)
            print(f'  physical nontrailing rows={len("\n".join(lines).rstrip().splitlines())}')
        # Long logical lines in history must reflow; the viewport keeps source layout.
        logical = ['L' * 100] + [str(i) for i in range(10)] + ['x' * 100] + [str(i) for i in range(40)] + ['END']
        start('wrap', '\r\n'.join(logical).encode(), 24, 40)
        c = Client(root, 'wrap')
        try:
            data = c.attach(1, 24, 40)
        finally:
            c.close()
        expected_rows = [s[i:i+60] for s in logical for i in range(0, len(s), 60)]
        check('wrap then resize 40 -> 60', [s for s in replay(data, 24, 40, 60) if s], expected_rows)
        start('nowrap', b'x' * 100 + b'\r\n\x1b[?7lEND', 24, 40)
        c = Client(root, 'nowrap')
        try:
            data = c.attach('legacy', 24, 40)
        finally:
            c.close()
        check('DECAWM off', [s for s in replay(data, 24, 40) if s], ['x'*40, 'x'*40, 'x'*20, 'END'])
        # '@' marks where the restored cursor lands; the prompt row must hold it.
        blank_continuation = b'a' * 25 + b'\x1b[2;1H\x1b[J\x1b[3;1Hnext\r\n$ ZEND'
        start('blankcont', blank_continuation, 6, 20)
        c = Client(root, 'blankcont')
        try:
            data = c.attach('legacy', 6, 20)
        finally:
            c.close()
        check('erased soft-wrap continuation, cursor', replay(data + b'@', 6, 20), replay(b'\x1bc' + blank_continuation + b'@', 6, 20))
        wide_payload = ('\r\n'.join([str(i) for i in range(5)] + ['x' * 100, '$ ZEND'])).encode()
        start('wider', wide_payload, 24, 40)
        c = Client(root, 'wider')
        try:
            data = c.attach(1, 24, 60)
        finally:
            c.close()
        check('wider receiver, cursor on prompt', [s for s in replay(data + b'@', 24, 60) if s][-1:], ['$ ZEND@'])
        for name, rows, cols, payload in [
            ('stale', 6, 20, b'\x1b[6G\x1b[12Gabcdefghijk\x1b[2K\x1b[2Kabcdefghijkl\r\nEND'),
            ('blank', 6, 20, b'123456789012345678901\x1b[1;1H\x1b[2K\x1b[3;1HEND'),
        ]:
            start(name, payload, rows, cols)
            c = Client(root, name)
            try:
                data = c.attach(1, rows, cols)
            finally:
                c.close()
            check(name, replay(data, rows, cols), replay(b'\x1bc' + payload, rows, cols))
        for name, rows, cols, payload, width in [
            ('boundary', 10, 40, ('\r\n'.join([str(i) for i in range(30)] + ['S'*485, 'END'])).encode(), 30),
            ('narrow', 4, 10, b'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX\r\nEND', 6),
        ]:
            start(name, payload, rows, cols)
            c = Client(root, name)
            try:
                data = c.attach(1, rows, cols)
            finally:
                c.close()
            actual = replay(data, rows, cols, width) if name == 'boundary' else replay(data, rows, width)
            expected = replay(b'\x1bc' + payload, rows, cols, width)
            actual = '\n'.join(actual).rstrip().splitlines()
            expected = '\n'.join(expected).rstrip().splitlines()
            mismatch = sum(a != b for a, b in zip(actual, expected)) + abs(len(actual) - len(expected))
            print(f'OBSERVE {name}: rows={len(actual)} reference={len(expected)} mismatches={mismatch}')
        c = Client(root, 'numbers')
        try:
            data = c.attach(1, 24, 80)
        finally:
            c.close()
        prompt = b'\x1b[24;1H\x1b]133;A\x07$ old'
        actual = [s for s in replay(prompt + b'\x1b[2J\x1b[H' + data, 24, 80) if s]
        print(f'OBSERVE existing prompt: old_prompt={"$ old" in actual} rows={len(actual)}')
        previous = b''
        for _ in range(2):
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            process = subprocess.Popen([binary, 'attach', 'numbers'], env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            def drain():
                output = b''
                while select.select([master], [], [], .3)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                return output
            try:
                attached = drain()
                os.write(master, b'\x1c')
                detached = drain()
                process.wait(timeout=4)
                assert b'\x1bc' in detached, 'normal detach did not emit RIS'
                actual = [s for s in replay(previous + attached, 24, 80) if s]
                previous += attached + detached
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=4)
                os.close(master)
        check('CLI repeat after normal detach (RIS)', actual, [str(i) for i in range(1, 501)] + ['END'])
        print(f'{total - failures}/{total} regression cases passed')
        return bool(failures)
    finally:
        for c in clients:
            c.close()
        for name in ['numbers', 'wrap', 'nowrap', 'blankcont', 'wider', 'stale', 'blank', 'boundary', 'narrow']:
            subprocess.run([binary, 'kill', name, '--force'], env=env, capture_output=True)
        subprocess.run(['trash', root])


if __name__ == '__main__':
    if sys.argv[1] == '--fixture':
        fixture(sys.argv[2])
    else:
        sys.exit(main(str(Path(sys.argv[1]).resolve())))
