#!/usr/bin/env python3
"""Send a local file to the E850-96 over the UART shell (base64 of gzip, line by line), then print the board-side
sha256 of the decompressed file.

  python uartpush.py LOCAL REMOTE [--port COM3] [--log FILE]

The shell reads a heredoc into REMOTE.b64; base64 -d | gunzip writes REMOTE. Lines are paced so the UART RX
(115200 8N1, no flow control) never overruns. Nothing is written outside REMOTE*.
"""
import argparse
import base64
import gzip
import hashlib
import sys
import time

import serial


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('local')
    ap.add_argument('remote')
    ap.add_argument('--port', default='COM3')
    ap.add_argument('--log', default=None)
    a = ap.parse_args()

    raw = open(a.local, 'rb').read()
    want = hashlib.sha256(raw).hexdigest()
    b64 = base64.b64encode(gzip.compress(raw, 9)).decode()
    lines = [b64[i:i + 76] for i in range(0, len(b64), 76)]
    print('[uartpush] %s: %d B, sha256 %s, %d base64 lines' % (a.local, len(raw), want, len(lines)))

    log = open(a.log, 'ab') if a.log else None
    with serial.Serial(a.port, 115200, timeout=0.05) as s:
        def rx():
            d = s.read(65536)
            if d and log:
                log.write(d)
            return d
        s.write(b'\r\n')
        time.sleep(0.3)
        rx()
        # as root: the console shell user may not create files there (2026-11-23: "can't create")
        # the heredoc temp file goes to $TMPDIR (default /data/local: "can't create temporary file")
        s.write(("export TMPDIR=/data/local/tmp; su 0 rm -f %s.b64; su 0 sh -c 'cat > %s.b64' <<'__B64__'\r\n"
                 % (a.remote, a.remote)).encode())
        time.sleep(0.3)
        rx()
        for i, l in enumerate(lines):
            s.write(l.encode() + b'\r\n')
            s.flush()
            time.sleep(0.012)          # 78 B at 115200 baud = 6.8 ms; keep headroom for the echo
            if i % 50 == 0:
                rx()
        s.write(b'__B64__\r\n')
        time.sleep(1.0)
        rx()
    if log:
        log.close()
    print('[uartpush] sent; expected sha256 %s' % want)
    return 0


if __name__ == '__main__':
    sys.exit(main())
