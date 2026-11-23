#!/usr/bin/env python3
"""fbmini.py - minimal fastboot client for the E850-96 Android 10 LK, for Windows (pyusb + libusb, WinUSB driver
installed with Zadig on USB\\VID_18D1&PID_0002 "Exynos3830 LK Bootloader").

Port of tools/linux510/fbmini.c (macOS/Homebrew libusb). The stock `fastboot` tool sends extra getvar queries
(product, has-slot, is-logical, ...) before flashing and this LK stops answering after some of them; on Windows
fastboot.exe also only sees devices on Google's AdbWinApi driver, not on WinUSB. fbmini sends only what it is told:

  python fbmini.py devices
  python fbmini.py getvar max-download-size
  python fbmini.py flash boot boot.img          (download:<size> + data, then flash:boot)
  python fbmini.py flash userdata rootfs-split.simg
  python fbmini.py reboot
  python fbmini.py cmd "<raw command>"          (use with care)

pip install --user pyusb libusb-package
"""
import os
import sys
import time

import libusb_package
import usb.backend.libusb1
import usb.core
import usb.util

VID, PID = 0x18D1, 0x0002
FB_CLASS, FB_SUBCLASS, FB_PROTO = 0xFF, 0x42, 0x03
CHUNK = 1024 * 1024


class Fastboot:
    def __init__(self):
        be = libusb_package.get_libusb1_backend()   # bundled libusb-1.0.dll (get_backend(find_library=...) gave None)
        self.dev = usb.core.find(idVendor=VID, idProduct=PID, backend=be)
        if self.dev is None:
            raise SystemExit('no fastboot device (18d1:0002)')
        cfg = self.dev.get_active_configuration()
        for intf in cfg:
            if (intf.bInterfaceClass, intf.bInterfaceSubClass, intf.bInterfaceProtocol) == \
                    (FB_CLASS, FB_SUBCLASS, FB_PROTO):
                self.intf = intf
                break
        else:
            raise SystemExit('no fastboot interface (ff/42/03)')
        usb.util.claim_interface(self.dev, self.intf.bInterfaceNumber)
        self.ep_out = usb.util.find_descriptor(self.intf, custom_match=lambda e:
                                               usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
        self.ep_in = usb.util.find_descriptor(self.intf, custom_match=lambda e:
                                              usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)
        try:
            self.serial = usb.util.get_string(self.dev, self.dev.iSerialNumber)
        except Exception:
            self.serial = '?'

    def close(self):
        usb.util.release_interface(self.dev, self.intf.bInterfaceNumber)
        usb.util.dispose_resources(self.dev)

    def reply(self, timeout_ms):
        """0 on OKAY, ('DATA', n) on DATA, -1 on FAIL; INFO/TEXT lines are printed and skipped."""
        while True:
            r = bytes(self.ep_in.read(256, timeout=timeout_ms)).decode('ascii', 'replace')
            print('< %s' % r, flush=True)
            if r.startswith(('INFO', 'TEXT')):
                continue
            if r.startswith('OKAY'):
                return 0
            if r.startswith('DATA'):
                return ('DATA', int(r[4:], 16))
            return -1

    def command(self, cmd, timeout_ms=5000):
        print('> %s' % cmd, flush=True)
        self.ep_out.write(cmd.encode(), timeout=5000)
        return self.reply(timeout_ms)

    def download(self, path):
        size = os.path.getsize(path)
        r = self.command('download:%08x' % size)
        if r != ('DATA', size):
            raise SystemExit('download not accepted: %r' % (r,))
        t0 = time.time()
        with open(path, 'rb') as f:
            done = 0
            while done < size:
                buf = f.read(min(CHUNK, size - done))
                n = self.ep_out.write(buf, timeout=10000)
                if n != len(buf):
                    raise SystemExit('data failed at %d' % done)
                done += n
                print('\r%d / %d' % (done, size), end='', file=sys.stderr, flush=True)
        print(' (%.1f s)' % (time.time() - t0), file=sys.stderr)
        if self.reply(30000) != 0:          # the OKAY that ends the data phase
            raise SystemExit('no OKAY after data')


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2
    fb = Fastboot()
    rc = 1
    try:
        if a[0] == 'devices':
            print('%s\tfastboot (18d1:0002, interface %d, ep out 0x%02x in 0x%02x)' %
                  (fb.serial, fb.intf.bInterfaceNumber, fb.ep_out.bEndpointAddress, fb.ep_in.bEndpointAddress))
            rc = 0
        elif a[0] == 'getvar' and len(a) == 2:
            rc = fb.command('getvar:%s' % a[1])
        elif a[0] == 'flash' and len(a) == 3:
            fb.download(a[2])
            rc = fb.command('flash:%s' % a[1], timeout_ms=600000)   # a 3 GB sparse image takes a while
        elif a[0] == 'reboot':
            rc = fb.command('reboot')
        elif a[0] == 'cmd' and len(a) == 2:
            rc = fb.command(a[1], timeout_ms=60000)
        else:
            print(__doc__)
            rc = 2
    finally:
        fb.close()
    return 0 if rc == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
