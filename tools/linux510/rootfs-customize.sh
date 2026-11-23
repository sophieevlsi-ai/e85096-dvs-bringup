#!/bin/bash
# Customisation of the Debian rootfs for build-rootfs-wsl.sh (mmdebstrap --customize-hook; root in a user
# namespace). Same steps and files as build-rootfs.sh.
#   R = the rootfs directory, S = the staging directory of build-rootfs-wsl.sh (t/ = tools/linux510 files,
#   mod/ = stripped modules after depmod, e850-blacklist.conf, wifi-a13.tgz)
set -eu
R=$1
S=$2
T=$S/t

echo e850-96 > $R/etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\te850-96\n' > $R/etc/hosts
printf 'LABEL=rootfs\t/\text4\tdefaults,noatime\t0\t1\n' > $R/etc/fstab

# Login: USB ACM gadget (ttyGS0, set up by the initramfs), autologin as root. The debug UART (ttySAC0) is kernel
# messages only: a getty on it hung the board (docs/E85096-LINUX510-BOOT.md 7.15), so its getty is masked.
mkdir -p $R/etc/systemd/system/serial-getty@ttyGS0.service.d
cat > $R/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf <<'EOT'
[Service]
ExecStart=
# opening ttyGS0 before the host has configured the gadget hangs the board (init comment)
ExecStartPre=/bin/sh -c 'until grep -qx configured /sys/class/udc/*/state; do sleep 1; done'
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200 %I $TERM
EOT
chroot $R systemctl enable serial-getty@ttyGS0.service
chroot $R systemctl mask serial-getty@ttySAC0.service
mkdir -p $R/etc/systemd/system/getty@tty1.service.d
cat > $R/etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOT'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOT

# Network over the USB NCM gadget: the board is 192.168.7.1 and hands the PC an address
mkdir -p $R/etc/systemd/network
cat > $R/etc/systemd/network/10-usb0.network <<'EOT'
[Match]
Name=usb0

[Network]
Address=192.168.7.1/24
DHCPServer=yes

[DHCPServer]
PoolOffset=10
PoolSize=10
EmitDNS=no
# no default route: otherwise the PC sends all its traffic to the board and loses internet
EmitRouter=no
EOT
chroot $R systemctl enable systemd-networkd.service

install -m 755 $T/rebootarg/rebootarg $R/usr/local/sbin/rebootarg
install -m 755 $T/to-fastboot $R/usr/local/sbin/to-fastboot
install -m 755 $T/lt8912b-hdmi.sh $R/usr/local/sbin/lt8912b-hdmi.sh
install -m 755 $T/fb-test.py $R/usr/local/bin/fb-test.py
install -m 755 $T/fb-hold.py $R/usr/local/bin/fb-hold.py
install -m 755 $T/ov5647-cap.py $R/usr/local/bin/ov5647-cap.py
install -m 755 $T/raw10-view.py $R/usr/local/bin/raw10-view.py
install -m 644 $T/e850-hdmi.service $R/etc/systemd/system/e850-hdmi.service
chroot $R systemctl enable e850-hdmi.service

# Wi-Fi (docs 10, 11.31, 11.47)
install -m 755 $T/e850-wifi.sh $R/usr/local/bin/e850-wifi.sh
install -m 644 $T/e850-wifi.service $R/etc/systemd/system/e850-wifi.service
chroot $R systemctl enable e850-wifi.service
mkdir -p $R/vendor/etc/wifi $R/lib/firmware $R/lib/etc
ln -sfn /vendor/etc/wifi $R/lib/etc/wifi
if [ -f $S/wifi-a13.tgz ]; then
    tar xzf $S/wifi-a13.tgz --no-same-owner -C $R/vendor/etc/wifi
    echo "wifi firmware: $(grep -a -m1 -o 'S612_E3830_[A-Z0-9_-]*' $R/vendor/etc/wifi/mx140.bin | head -1)"
else
    echo "WARNING: no wifi-a13.tgz, the image has no Wi-Fi firmware"
fi

# Student account (same as build-rootfs.sh)
chroot $R useradd -m -s /bin/bash -G sudo,video,i2c e850 2>/dev/null || chroot $R useradd -m -s /bin/bash -G sudo,video e850
echo 'e850:e850' | chroot $R chpasswd

# Kernel modules (stripped and depmod-ed outside the namespace)
cp -a $S/mod/lib/modules $R/lib/
KVER=$(ls $S/mod/lib/modules)
chown -R 0:0 $R/lib/modules
[ -f $R/lib/modules/$KVER/e850-cpuhp.ko ] && echo e850-cpuhp > $R/etc/modules-load.d/e850-cpuhp.conf
mkdir -p $R/etc/modprobe.d
install -m 644 $S/e850-blacklist.conf $R/etc/modprobe.d/e850-blacklist.conf

rm -rf $R/var/cache/apt/archives/*.deb $R/var/lib/apt/lists/*
echo "modules in rootfs: $(ls $R/lib/modules/$KVER/*.ko | wc -l) ($KVER)"
