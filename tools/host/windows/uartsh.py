#!/usr/bin/env python3
"""Run one shell command on the E850-96 UART console (Windows COM port) and print its output.

  python uartsh.py "id; ls /sys/class/udc" [--port COM3] [--timeout 20] [--log FILE]

The Android 10 eng build starts `console:/ $` on ttySAC0 (115200 8N1). Kernel printk lines share the
same UART, so the command output is taken between two marker lines and kernel lines are dropped.
Every byte received is also appended to the log file (raw evidence for the report).
"""
import argparse
import datetime
import re
import sys
import time

import serial

KLINE = re.compile(r'^\[\s*\d+\.\d+\]')     # "[   36.2] ..." kernel printk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd')
    ap.add_argument('--port', default='COM3')
    ap.add_argument('--timeout', type=float, default=20)
    ap.add_argument('--log', default=None)
    ap.add_argument('--keep-klines', action='store_true', help='keep [ time] lines (for dmesg output)')
    a = ap.parse_args()

    tag = 'E850_%d' % (time.time() * 1000 % 1e9)
    start, end = '__S_%s__' % tag, '__E_%s__' % tag
    # the markers are built at run time so the echoed command line itself never matches them
    line = "echo __S_%s__; %s; echo __E_%s__ rc=$?" % (tag, a.cmd, tag)
    line = line.replace('__S_%s__' % tag, "__S_'%s'__" % tag, 1)
    line = line.replace('__E_%s__' % tag, "__E_'%s'__" % tag, 1)

    log = open(a.log, 'ab') if a.log else None
    if log:
        log.write(('\n### %s %s $ %s\n' % (datetime.datetime.now().isoformat(), a.port, a.cmd)).encode())

    with serial.Serial(a.port, 115200, timeout=0.2) as s:
        s.reset_input_buffer()
        s.write(b'\r\n')
        time.sleep(0.3)
        s.write(line.encode() + b'\r\n')
        buf = b''
        t0 = time.time()
        while time.time() - t0 < a.timeout:
            d = s.read(4096)
            if d:
                buf += d
                if log:
                    log.write(d)
                if end.encode() in buf:
                    time.sleep(0.2)
                    rest = s.read(4096)
                    buf += rest
                    if log:
                        log.write(rest)
                    break
    if log:
        log.close()

    text = buf.decode('utf-8', 'replace').replace('\r', '')
    if start not in text:
        print('[uartsh] no output marker: is the shell prompt there? raw tail:\n' + text[-800:], file=sys.stderr)
        return 2
    body = text.split(start, 1)[1]
    rc = None
    if end in body:
        body, tail = body.split(end, 1)
        m = re.search(r'rc=(\d+)', tail)
        rc = int(m.group(1)) if m else None
    else:
        print('[uartsh] timeout before end marker', file=sys.stderr)
    out = [l for l in body.split('\n') if l.strip() and (a.keep_klines or not KLINE.match(l.strip()))]
    print('\n'.join(out))
    print('[uartsh] rc=%s' % rc, file=sys.stderr)
    return 0 if rc == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
