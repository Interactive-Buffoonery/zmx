#!/usr/bin/env python3
"""Real-daemon attach -> fresh Ghostty terminal; compare ordered rows.

zig build test-replay && python3 test/attach_scrollback.py zig-out/bin/zmx
"""
import os
import fcntl
import pty
import re
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
    sessions = []
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
        sessions.append(name)
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
        if isinstance(actual, (int, bool)):
            actual, expected = [actual], [expected]
        mismatch = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b), min(len(actual), len(expected)))
        print(f'{"PASS" if ok else "FAIL"} {label}: got={actual!r} expected={expected!r}' if label.startswith('state ') else f'{"PASS" if ok else "FAIL"} {label}: got={len(actual)} expected={len(expected)} first_mismatch={mismatch}', flush=True)

    try:
        def snapshot(name, payload):
            start(name, payload, 6, 40)
            c = Client(root, name)
            try:
                return c.attach(1, 6, 40)
            finally:
                c.close()

        def state(data, cols=40):
            replay(data, 6, cols)
            return Path(root + '/text.state').read_text().splitlines()

        long_line = b'A' * 100
        data = snapshot('wrap-retained', long_line + b'\r\n' + b'x\r\n' * 10 + b'END')
        check('receiver retaining DECAWM off keeps long history', replay(b'\x1b[?7l' + data, 6, 40), replay(data, 6, 40))

        data = snapshot('origin-saved', b'\x1b[2;5r\x1b[?6h\x1b[?1049h\x1b[?6lEND')
        after_exit = replay(data + b'\x1b[?1049l\x1b[1;1HX', 6, 40)
        check('1049 exit restores saved origin mode', after_exit[1], 'X')

        data = snapshot('origin-margins', b'\x1b[2;5r\x1b[?6h\x1b[3;7HP\x1b[?1049h\x1b[?6lEND')
        check('retained margins do not shift the primary cursor', replay(b'\x1b[2;5r' + data + b'\x1b[?1049l@', 6, 40)[3], '      P@')

        data = snapshot('history-margins', b'\r\n'.join(b'%d' % i for i in range(30)) + b'\r\nEND')
        check('retained margins keep history', replay(b'\x1b[2;5r\x1b[?6h' + data, 6, 40), replay(data, 6, 40))

        data = snapshot('origin-alt', b'\x1b[?1049h\x1b[2;5r\x1b[?6hEND')
        check('alt keeps its own origin mode', replay(data + b'\x1b[1;1HX', 6, 40)[1], 'XND')

        for code, style, blink in [(1, 'block', True), (2, 'block', False),
                                   (3, 'underline', True), (4, 'underline', False),
                                   (5, 'bar', True), (6, 'bar', False)]:
            data = snapshot(f'cursor{code}', f'END\x1b[{code} q'.encode())
            check(f'state cursor {code}', state(data)[0],
                  f'cursor={style},{str(blink).lower()},false at=3,0')
        for prefix, label in [(b'', 'shared'), (b'\x1b[2 q', 'alt only')]:
            payload = b'\x1b[5 q\x1b[?1049h' + prefix + b'ALT\r\nEND'
            data = snapshot('primarystyle' + label[:1], payload)
            check(f'state primary cursor style after exit, {label}', state(data + b'\x1b[?1049l')[0].split(' ')[0], state(b'\x1bc' + payload + b'\x1b[?1049l')[0].split(' ')[0])
        data = snapshot('defaults', b'END')
        check('state default extra bytes', len(re.findall(rb'\x1b\[[0-9]* q|\x1b\]4;[^\x1b]*\x1b\\|\x1b\[3g|\x1bH', data)), 0)
        data = snapshot('cursorreset', b'END\x1b[5 q\x1b[0 q')
        check('state cursor reset', state(data)[0], 'cursor=block,false,true at=3,0')
        check('state cursor reset bytes', b' q' in data, False)
        colors = b'END\x1b]4;1;rgb:12/34/56\x1b\\\x1b]4;255;rgb:ab/cd/ef\x1b\\'
        data = snapshot('palette', colors)
        check('state palette 1', state(data)[2], '1=123456')
        check('state palette 255', state(data)[256], '255=abcdef')
        check('state palette emitted entries', data.count(b'\x1b]4;'), 2)
        data = snapshot('palettereset', colors + b'\x1b]104\x1b\\')
        check('state palette reset bytes', data.count(b'\x1b]4;'), 0)
        for name, tabs in [('customtabs', b'\x1b[3g\x1b[14G\x1bH\x1b[30G\x1bH'),
                           ('notabs', b'\x1b[3g')]:
            payload = tabs + b'\x1b[3;2HEND'
            data = snapshot(name, payload)
            check(f'state {name} cursor', state(data)[0], state(b'\x1bc' + payload)[0])
            for cols in (40, 60, 10):
                check(f'state {name} TAB cols={cols}', replay(data + b'\t@', 6, cols),
                      replay(b'\x1bc' + payload + b'\t@', 6, cols))
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
        # Compare every physical row, including blanks; '@' probes both cursors.
        primary = ('\r\n'.join(str(i) for i in range(1, 501))).encode() + b'\x1b[2;7H'
        for mode in (1049, 1047, 47, 'mixed'):
            enter = b'\x1b[?1049h\x1b[?47h\x1b[?1047h' if mode == 'mixed' else f'\x1b[?{mode}h'.encode()
            leave = b'\x1b[?1049l' if mode == 'mixed' else f'\x1b[?{mode}l'.encode()
            payload = primary + enter + b'\x1b[HALT\x1b[3;1HEND\x1b[2;6H'
            name = f'alt{mode}'
            start(name, payload, 4, 20)
            for role, rows in [('legacy', 4), (1, 8), (2, 8)]:
                c = Client(root, name)
                try:
                    data = c.attach(role, rows, 20)
                finally:
                    c.close()
                label = f'alt {mode} role={role} rows={rows}'
                for prefix, receiver in [(b'', 'fresh'), (b'\x1b[?1049hOLDALT', 'already-alt')]:
                    expected_alt = replay(b'\x1bc' + payload + b'@', 4, 20) + [''] * (rows - 4)
                    check(label + ' ' + receiver + ' active cursor', replay(prefix + data + b'@', rows, 20), expected_alt)
                    expected_primary = replay(b'\x1bc' + payload + leave + b'@', 4, 20) + [''] * (rows - 4)
                    check(label + ' ' + receiver + ' primary cursor', replay(prefix + data + leave + b'@', rows, 20), expected_primary)
                print(f'  {label} snapshot_bytes={len(data)}')
        small_primary = b'1\r\n2\r\n3\r\n4\r\n5\x1b]2;END\x07'
        start('primary', small_primary, 4, 10)
        c = Client(root, 'primary')
        try:
            data = c.attach('legacy', 4, 10)
        finally:
            c.close()
        for prefix, receiver in [(b'', 'fresh guard'), (b'\x1b[?1049hOLDALT', 'already-alt')]:
            check('non-alt ' + receiver + ' cursor', replay(prefix + data + b'@', 4, 10), replay(b'\x1bc' + small_primary + b'@', 4, 10))
        large_primary = ('\r\n'.join(str(i) for i in range(1, 10001))).encode()
        start('largealt', large_primary + b'\x1b[?1049hEND', 24, 80)
        c = Client(root, 'largealt')
        try:
            data = c.attach(1, 24, 80)
        finally:
            c.close()
        print(f'SIZE 10000-line primary + alt: {len(data)} bytes (limit={8 * 1024 * 1024})')
        check('10000-line snapshot fits phone', [len(data) < 8 * 1024 * 1024], [True])
        check('10000-line primary after exit cursor', replay(data + b'\x1b[?1049l@', 24, 80), [str(i) for i in range(1, 10000)] + ['10000@'])
        # A primary that never reset its pen or charset must not restyle alt.
        leak = b'prompt\x1b(0\x1b[?1049h\x1b(Bqqq\r\nEND'
        start('charset', leak, 6, 20)
        c = Client(root, 'charset')
        try:
            data = c.attach('legacy', 6, 20)
        finally:
            c.close()
        check('primary charset stays out of alt', replay(data, 6, 20), replay(b'\x1bc' + leak, 6, 20))
        # Client died on alt: its uncleared primary must not show through.
        stale = b'STALE\r\nSTALE2\x1b[?1049h'
        start('nohist', b'hi\r\nEND', 6, 20)
        c = Client(root, 'nohist')
        try:
            data = c.attach('legacy', 6, 20)
        finally:
            c.close()
        check('stale receiver primary, no history', replay(stale + data, 6, 20), replay(b'\x1bc' + b'hi\r\nEND', 6, 20))
        start('hist', b'\r\n'.join(str(i).encode() for i in range(1, 11)) + b'\r\nEND', 4, 20)
        c = Client(root, 'hist')
        try:
            data = c.attach('legacy', 4, 20)
        finally:
            c.close()
        check('stale receiver primary, history', [s for s in replay(stale + data, 4, 20) if s], [str(i) for i in range(1, 11)] + ['END'])
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
        for name in sessions:
            subprocess.run([binary, 'kill', name, '--force'], env=env, capture_output=True)
        subprocess.run(['trash', root])


if __name__ == '__main__':
    if sys.argv[1] == '--fixture':
        fixture(sys.argv[2])
    else:
        sys.exit(main(str(Path(sys.argv[1]).resolve())))
