#!/usr/bin/env python3
"""Back up E850-96 partitions over ADB in chunks, restarting adbd over the UART shell between sessions.

Observed 2026-11-23 (Android 10 eng, Linaro dtbo-peri, Windows adb 37.0.3 and 33.0.3): every ADB USB session
dies after ~12-20 MB of bulk data ("AdbUsbConnection: terminated (data)", board sees no disconnect).
Workaround: 1 MiB chunks, each checked against the board's sha256; after a failed chunk `setprop ctl.restart adbd`
over the UART shell (uartsh.py) and retry. The LK fastboot transfer on the same cable and port did not drop.

  set E850_ADB=C:\\path\\to\\platform-tools\\adb.exe    (default: adb on PATH)
  python adbchunkpull.py OUTDIR "15 boot" "17 recovery" ...    (partition number + name)
"""
import hashlib
import os
import subprocess
import sys
import time

ADB = os.environ.get('E850_ADB', 'adb')
UARTSH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uartsh.py')
CHUNK = 1 << 20          # 2026-11-23: failures are intermittent, not data-dependent -> small chunks, more retries
SESSION_BYTES = 1 << 40  # restart adbd only after a failure
TMP = '/data/local/tmp/bk'


def adb(*args, timeout=60):
    return subprocess.run([ADB, *args], capture_output=True, text=True, timeout=timeout)


def restart_adbd():
    subprocess.run([ADB, 'kill-server'], capture_output=True)
    for attempt in range(5):
        subprocess.run([sys.executable, UARTSH, 'su 0 setprop ctl.restart adbd; sleep 2; getprop init.svc.adbd'],
                       capture_output=True, timeout=30)
        for _ in range(20):
            time.sleep(0.5)
            if adb('get-state', timeout=10).stdout.strip() == 'device':
                return
    raise SystemExit('adb did not come back')


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    restart_adbd()
    sent = 0
    for spec in sys.argv[2:]:
        n, name = spec.split()
        dev = '/dev/block/mmcblk0p%s' % n
        size = int(adb('shell', 'su 0 blockdev --getsize64 %s' % dev).stdout.strip())
        board_sha = adb('shell', 'su 0 sha256sum %s' % dev, timeout=300).stdout.split()[0]
        nchunks = (size + CHUNK - 1) // CHUNK
        dst = os.path.join(out, '%s_p%s.img' % (name, n))
        t0 = time.time()
        with open(dst, 'wb') as f:
            for i in range(nchunks):
                for attempt in range(10):
                    if sent + CHUNK > SESSION_BYTES:
                        restart_adbd()
                        sent = 0
                    remote = '%s/c' % TMP
                    adb('shell', 'su 0 sh -c "mkdir -p %s; dd if=%s of=%s bs=%d skip=%d count=1 2>/dev/null; '
                        'chmod 644 %s"' % (TMP, dev, remote, CHUNK, i, remote))
                    want = adb('shell', 'su 0 sha256sum %s' % remote).stdout.split()[0]
                    local = dst + '.part'
                    r = adb('pull', remote, local, timeout=120)
                    sent += CHUNK
                    if r.returncode == 0 and os.path.exists(local) and \
                            hashlib.sha256(open(local, 'rb').read()).hexdigest() == want:
                        f.write(open(local, 'rb').read())
                        os.remove(local)
                        break
                    print('  %s chunk %d attempt %d failed; restarting adbd' % (name, i, attempt), flush=True)
                    restart_adbd()
                    sent = 0
                else:
                    raise SystemExit('%s chunk %d failed 10 times' % (name, i))
        adb('shell', 'su 0 rm -f %s/c' % TMP)
        pc_sha = hashlib.sha256(open(dst, 'rb').read()).hexdigest()
        print('%s p%s size=%d board=%s pc=%s %s %.0fs' % (name, n, os.path.getsize(dst), board_sha, pc_sha,
              'MATCH' if pc_sha == board_sha else 'MISMATCH', time.time() - t0), flush=True)


if __name__ == '__main__':
    main()
