# Windows host tools for the E850-96 (no WSL needed for these)

Windows 11, Python 3.11: `pip install --user pyserial pyusb libusb-package`. Tested on 2026-11-23 with one E850-96
(Android 10 eng `full_erd850`, LK `Dec 13 2022`) and the vendor 5.10 + Debian 12 images of `tools/linux510`.
See [docs/WINDOWS-WSL2-LINUX510-REPRO.md](../../../docs/WINDOWS-WSL2-LINUX510-REPRO.md).

| Tool | Use | Notes |
|---|---|---|
| `uartsh.py` | Run one command on the UART shell (`console:/ $` of the Android 10 eng build on ttySAC0, 115200 8N1, COM port of the 1.8 V USB-UART) or on the Linux USB ACM login (`--port COM4`) and print only its output | Output is cut between two marker lines; kernel printk lines are dropped unless `--keep-klines`. `--log FILE` appends every received byte |
| `uartpush.py` | Copy a small file to the board over the UART shell (gzip + base64 heredoc, written as root to e.g. `/data/local/tmp`) | ~11 KB/s. Used to write the Linaro `dtbo-peri.img` before ADB worked |
| `adbchunkpull.py` | Back up partitions over ADB in 1 MiB chunks, each checked against the board's sha256; restarts adbd over UART after a failed chunk | On this board ADB bulk transfers dropped every ~12-20 MB with Windows adb 37.0.3 and 33.0.3 (`AdbUsbConnection: terminated (data)`), while LK fastboot on the same cable did not |
| `fbmini.py` | Port of `tools/linux510/fbmini.c`: fastboot client that sends only `download`, `flash`, `getvar`, `reboot` | Needs the WinUSB driver on `USB\VID_18D1&PID_0002` ("Exynos3830 LK Bootloader"), installed with Zadig. Windows `fastboot.exe` does not see a WinUSB (Zadig) device |

## J1 (micro-USB) ADB on Android 10

The stock dtbo of this board is Linaro's `dtbo-host.img` (byte-identical): `dr_mode = "host"`, so J1 never shows up on
the PC (`/sys/class/udc` empty). Linaro's `dtbo-peri.img` differs only in that line (`"peripheral"`). After writing it
to the dtbo partition (p5), J1 enumerates as `USB\VID_04E8&PID_6860` with the Samsung ADB interface.

## Typical sequence

```powershell
python uartsh.py "su 0 reboot bootloader"          # LK: "Entering fastboot: reboot bootloader command"
python fbmini.py devices
python fbmini.py getvar max-download-size           # OKAY805306368 (768 MiB)
python fbmini.py flash boot boot.img
python fbmini.py flash userdata rootfs-split.simg   # resparse.py output: no FILL chunk over 32 MiB
python fbmini.py reboot
python uartsh.py "uname -a" --port COM4             # Linux USB ACM gadget (VID 1d6b PID 0104)
```
