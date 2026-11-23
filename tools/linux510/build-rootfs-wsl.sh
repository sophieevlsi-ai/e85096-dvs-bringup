#!/bin/bash
# build-rootfs.sh for an x86-64 host (Windows 11 + WSL2 Ubuntu 24.04), without Docker and without root.
#
# Same Debian 12 arm64 rootfs as build-rootfs.sh, built rootless:
#   - debootstrap in a --privileged arm64 container -> mmdebstrap --mode=unshare (user namespace) with the host's
#     qemu-aarch64 binfmt handler (flag F) running the arm64 maintainer scripts and chroot commands
#   - the customisation of build-rootfs.sh runs as a mmdebstrap --customize-hook (rootfs-customize.sh)
#   - "root" in the namespace is a subordinate uid: it cannot read a 0750 home directory. Every input the
#     namespace needs (keyring, tools/linux510 files, stripped modules, Wi-Fi firmware) is staged in a
#     world-readable directory under /tmp first.
#   - strip -> aarch64-linux-gnu-strip; depmod -> the host's depmod -b (both outside the namespace)
#   - mke2fs -d takes the tarball directly (e2fsprogs >= 1.47), so file owners survive without root
# Host packages: mmdebstrap, qemu-user-static, binfmt-support, e2fsprogs (>= 1.47), android-sdk-libsparse-utils,
#   binutils-aarch64-linux-gnu, kmod. Ubuntu has no Debian archive keys: KEYRING = debian-archive-keyring.gpg,
#   e.g. `apt-get download debian-archive-keyring` (checked by Ubuntu's apt, no root) and dpkg-deb -x.
#
#   KEYRING=.../debian-archive-keyring.gpg O=~/e850/out OUT=~/e850/rootfs-out [SIZE=3G] build-rootfs-wsl.sh
# Output: $OUT/rootfs.simg -> userdata (mmcblk0p24). Wi-Fi firmware: $OUT/wifi-a13.tgz from wifi-fw-linaro.py.
set -eu
T=$(cd "$(dirname "$0")" && pwd)
O=${O:?O=kernel build output}
OUT=${OUT:?OUT=output directory}
SIZE=${SIZE:-3G}
STRIP=${STRIP:-aarch64-linux-gnu-strip}
KEYRING=${KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}
[ -f "$KEYRING" ] || { echo "KEYRING not found: $KEYRING" >&2; exit 1; }
mkdir -p "$OUT"
rm -f "$OUT/rootfs.tar" "$OUT/rootfs.ext4" "$OUT/rootfs.simg"

# 1. stage the inputs where the namespace can read them
S=$(mktemp -d /tmp/e850-rootfs.XXXXXX)
trap 'rm -rf "$S"' EXIT
chmod 755 "$S"
cp "$KEYRING" "$S/keyring.gpg"
mkdir -p "$S/t/rebootarg"
cp "$T"/{rootfs-customize.sh,to-fastboot,lt8912b-hdmi.sh,fb-test.py,fb-hold.py,ov5647-cap.py,raw10-view.py,e850-hdmi.service,e850-wifi.sh,e850-wifi.service} "$S/t/"
cp "$T/rebootarg/rebootarg" "$S/t/rebootarg/"
[ -f "$OUT/wifi-a13.tgz" ] && cp "$OUT/wifi-a13.tgz" "$S/wifi-a13.tgz"
KVER=$(cat "$O/include/config/kernel.release")
M=$S/mod/lib/modules/$KVER
mkdir -p "$M"
while read -r m; do
    $STRIP --strip-debug -o "$M/$(basename "$m")" "$O/$m"
done < "$O/modules.order"
for extra in "$O"/ext-*/*.ko; do
    [ -f "$extra" ] && $STRIP --strip-debug -o "$M/$(basename "$extra")" "$extra" || true
done
cp "$O/modules.order" "$O/modules.builtin" "$O/modules.builtin.modinfo" "$M/" 2>/dev/null || true
depmod -b "$S/mod" "$KVER"
{ echo "# generated from tools/linux510/autoload.deny by build-rootfs-wsl.sh"
  sed 's|.*/||; s|\.ko$||' "$O/modules.order" | grep -Ef "$T/autoload.deny" | sed 's|^|blacklist |'
} > "$S/e850-blacklist.conf"
chmod -R a+rX "$S"
echo "staged: $(ls "$M"/*.ko | wc -l) modules, $(grep -c ^blacklist "$S/e850-blacklist.conf") blacklisted"

# 2. rootfs
export S
mmdebstrap --mode=unshare --arch=arm64 --variant=minbase --keyring="$S/keyring.gpg" \
    --include=systemd-sysv,udev,kmod,iproute2,iputils-ping,procps,less,nano,sudo,openssh-server,i2c-tools,v4l-utils,python3,python3-numpy,ca-certificates,dbus,wpasupplicant,iw,wireless-regdb \
    --customize-hook='bash "$S/t/rootfs-customize.sh" "$1" "$S"' \
    bookworm "$OUT/rootfs.tar" http://deb.debian.org/debian

# 3. image. mke2fs -d reads a tarball only from e2fsprogs 1.47.1 (Ubuntu 24.04 has 1.47.0: "Not a directory"):
#    unpack under fakeroot (owners, modes and device nodes kept in its state file) and populate from the directory.
#    File capabilities (security.capability xattrs, e.g. ping) are not carried over by fakeroot.
if mke2fs -q -t ext4 -L rootfs -d "$OUT/rootfs.tar" "$OUT/rootfs.ext4" "$SIZE" 2>/dev/null; then
    echo "mke2fs populated from the tarball"
else
    rm -f "$OUT/rootfs.ext4"
    D=$(mktemp -d "$OUT/rootfs-dir.XXXXXX")
    fakeroot -s "$D.fakeroot" -- tar --numeric-owner -xpf "$OUT/rootfs.tar" -C "$D"
    fakeroot -i "$D.fakeroot" -- mke2fs -q -t ext4 -L rootfs -d "$D" "$OUT/rootfs.ext4" "$SIZE"
    rm -rf "$D" "$D.fakeroot"
    echo "mke2fs populated from a fakeroot directory"
fi
img2simg "$OUT/rootfs.ext4" "$OUT/rootfs.simg"
rm -f "$OUT/rootfs.ext4"
ls -l "$OUT/rootfs.tar" "$OUT/rootfs.simg"
