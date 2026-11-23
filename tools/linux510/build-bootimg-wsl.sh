#!/bin/bash
# build-bootimg.sh for an x86-64 host (Windows 11 + WSL2 Ubuntu 24.04), without Docker or root.
#
# Same image as build-bootimg.sh (boot.img header v2 = Image + busybox initramfs + merged DTB for the
# Android 10 LK); only the host-dependent parts change:
#   - busybox: build-bootimg.sh copies the container's /bin/busybox, which is ARM64 only because Apple
#     Silicon Docker runs arm64 natively. On x86 that would put an x86 binary in the initramfs.
#     Here BUSYBOX must point at an ARM64 static busybox (e.g. Ubuntu jammy busybox-static_*_arm64.deb,
#     the same package the ubuntu:22.04 container installs).
#   - strip: the native strip of the container; here the cross binutils (aarch64-linux-gnu-strip).
#   - mknod / root-owned files: run under fakeroot (no sudo).
#   - no apt-get inside: the host needs kmod, device-tree-compiler (fdtoverlay, fdtput), cpio, python3,
#     binutils-aarch64-linux-gnu, fakeroot.
#
#   O=~/e850/out OUT=~/e850/boot-out BUSYBOX=.../bin/busybox [BACKUP=.../boot_p15.img.gz] \
#       tools/linux510/build-bootimg-wsl.sh [root=PARTLABEL=userdata]
#
# Inputs : O       kernel build output (Image, dtb, dtbo, *.ko, modules.order, ext-*/ modules)
#          BACKUP  optional: the board's stock Android 10 boot partition, gzip (restore-android)
# Outputs: OUT     boot.img, initramfs.cpio.gz, merged.dtb, cmdline.txt
set -eu
if [ -z "${FAKEROOTKEY:-}" ]; then exec fakeroot -- "$0" "$@"; fi
ROOTARG=${1:-}
T=$(cd "$(dirname "$0")" && pwd)
O=${O:?O=kernel build output}
OUT=${OUT:?OUT=output directory}
BUSYBOX=${BUSYBOX:?BUSYBOX=ARM64 static busybox}
STRIP=${STRIP:-aarch64-linux-gnu-strip}
BACKUP=${BACKUP:-}
file -L "$BUSYBOX" | grep -q 'ARM aarch64' || { echo "BUSYBOX is not an ARM64 binary: $BUSYBOX" >&2; exit 1; }
file -L "$BUSYBOX" | grep -q 'statically linked' || { echo "BUSYBOX is not static: $BUSYBOX" >&2; exit 1; }

KVER=$(cat $O/include/config/kernel.release)
IRD=$(mktemp -d)/initramfs
MODDIR=$IRD/lib/modules/$KVER
mkdir -p $IRD/bin $IRD/dev $MODDIR $OUT

# 1. busybox + init + rescue helpers; /dev/console so the kernel can open the initial console
cp "$BUSYBOX" $IRD/bin/busybox && chmod 755 $IRD/bin/busybox
cp $T/init $IRD/init && chmod 755 $IRD/init
for h in part-dev restore-android to-fastboot; do cp $T/$h $IRD/bin/$h && chmod 755 $IRD/bin/$h; done
cp $T/rebootarg/rebootarg $IRD/bin/rebootarg && chmod 755 $IRD/bin/rebootarg
mknod -m 600 $IRD/dev/console c 5 1
if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    mkdir -p $IRD/restore && cp "$BACKUP" $IRD/restore/boot-android10.img.gz
else
    echo "no BACKUP (stock boot .img.gz): restore-android will not work" >&2
fi

# 2. modules: all of them, without debug info (autoload order as in build-bootimg.sh)
while read -r m; do
    f=$O/$m
    [ -f "$f" ] || { echo "missing $m" >&2; continue; }
    $STRIP --strip-debug -o $MODDIR/$(basename "$m") "$f"
done < $O/modules.order
for f in $O/ext-*/*.ko; do
    [ -f "$f" ] && $STRIP --strip-debug -o $MODDIR/$(basename "$f") "$f" || true
done
{ grep -v '^#' $T/vendor_boot_module_order_s5e3830.cfg; sed 's|.*/||' $O/modules.order; } |
    awk 'NF && !seen[$0]++' | grep -vEf $T/autoload.deny > $MODDIR/modules.load
grep -v '^#' $T/modules.stage1 > $MODDIR/modules.stage1
cp $O/modules.builtin $MODDIR/ 2>/dev/null || true
cp $O/modules.order $MODDIR/
depmod -b $IRD "$KVER"
echo "modules: $(ls $MODDIR/*.ko | wc -l) copied, $(wc -l < $MODDIR/modules.load) autoload"

(cd $IRD && find . | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0 | gzip -9n) > $OUT/initramfs.cpio.gz

# 3. DTB: SoC dtb + board overlay, CPU reg = cluster<<8 | core, bootargs (see build-bootimg.sh)
DTS=$O/arch/arm64/boot/dts/exynos
fdtoverlay -i $DTS/s5e3830.dtb -o $OUT/merged.dtb $DTS/board/erd/s5e3830-erd3830.dtbo
for c in 0 1 2 3 4 5 6 7; do fdtput -t x $OUT/merged.dtb /cpus/cpu@000$c reg 0 $(printf %x $(( (c / 4) << 8 | c % 4 ))); done
VTPAL="vt.default_red=0,170,0,170,0,170,0,255,85,255,85,255,85,255,85,255 vt.default_grn=0,0,170,85,0,0,170,255,85,85,255,255,85,85,255,255 vt.default_blu=0,0,0,0,170,170,170,255,85,85,85,85,255,255,255,255"
CMDLINE="console=ram keep_bootcon earlycon=exynos4210,mmio32,0x13820000 cpuidle.off=1 panic=0 fbcon=font:TER16x32 $VTPAL clocksource=arch_sys_counter clk_ignore_unused printk.devkmsg=on loglevel=8 ignore_loglevel firmware_class.path=/lib/firmware $ROOTARG"
fdtput -t s $OUT/merged.dtb /chosen bootargs "$CMDLINE"
echo "$CMDLINE" > $OUT/cmdline.txt

# 4. boot.img
python3 $T/mkbootimg_v2.py --kernel $O/arch/arm64/boot/Image --ramdisk $OUT/initramfs.cpio.gz \
    --dtb $OUT/merged.dtb -o $OUT/boot.img
rm -rf "$(dirname $IRD)"
ls -l $OUT
