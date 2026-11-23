#!/bin/bash
# Build the vendor 5.10 kernel (Image, modules, dtbs) for the E850-96 on an x86-64 host (Windows 11 + WSL2 Ubuntu
# 24.04), natively, without Docker. Replaces the e850-build-env:1 container + ~/e850-a13-build volume of the Mac flow.
#
#   K=~/e850/kernel O=~/e850/out CLANG=~/e850/a13-build/prebuilts/clang/host/linux-x86/clang-r450784e \
#       tools/linux510/build-kernel-wsl.sh
#
#   K     Linaro android-exynos-5.10-linaro, 3b6b9ca5 (gitlab.com/Linaro/96boards/e850-96/kernel)
#   CLANG AOSP prebuilts/clang/host/linux-x86 clang-r450784e (Android clang 14.0.7, build 8508608); the
#         master-kernel-build-2022 branch of platform/prebuilts/clang/host/linux-x86 has it as a +archive tarball
#
# What differs from running the same make in the container (found 2026-11-23):
#  - scripts/kconfig/merge_config.sh ends with "make alldefconfig" and needs ARCH/LLVM in the environment; without
#    them it configures for the host (x86) and drops every ARM64 vendor option (3 modules left instead of 162).
#  - Ubuntu 24.04 has no `python`; link-vmlinux.sh calls it (Error 127). A python -> python3 shim goes first in PATH.
#  - The public Linaro tree has no S5KRC1S registration; modules/s5krc1s-pablo/apply.sh now adds it.
#  - s5e3830.dts has //#include "s5e3830-dpu.dtsi"; modules/e850-hdmi/apply.sh now uncomments it (overlay symbols).
# The config fragments (gki + s5e3830-base + erd3830_t + erd3830_t_mali + s5e3830_userdebug) are our choice: the
# exact set of the Mac build is not recorded. The resulting Image had the same size (46,926,148 B) as docs 1.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
K=${K:?K=kernel source}
O=${O:?O=build output}
CLANG=${CLANG:?CLANG=clang-r450784e directory}
JOBS=${JOBS:-$(nproc)}
SHIM=$(mktemp -d)
trap 'rm -rf "$SHIM"' EXIT
command -v python >/dev/null || ln -s "$(command -v python3)" "$SHIM/python"
export PATH=$SHIM:$CLANG/bin:$PATH
export ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-
MK="make -C $K O=$O TARGET_SOC=s5e3830 KCFLAGS=-D__ANDROID_COMMON_KERNEL__"
clang --version | head -1

# 1. course patches (order matters: the s5krc1s overlay replaces the ov5647 include, e850-hdmi adds its include
#    after the ov5647 line)
for s in ov5647-pablo/apply.sh e850-hdmi/apply.sh s5krc1s-pablo/apply.sh ov5647-pablo/bypass.sh \
         s3c2410-wdt/apply.sh scsc-wifi/apply.sh; do
    echo "-- $s"
    sh "$R/modules/$s" "$K" > /dev/null
done
grep -n 'camera/\|e850-hdmi' "$K/arch/arm64/boot/dts/exynos/board/erd/s5e3830-erd3830.dts"

# 2. config
C=$K/arch/arm64/configs
mkdir -p "$O"
(cd "$K" && scripts/kconfig/merge_config.sh -m -O "$O" "$C/gki_defconfig" "$C/s5e3830-base_defconfig" \
    "$C/erd3830_t_defconfig" "$C/erd3830_t_mali.cfg" "$C/s5e3830_userdebug.cfg" > "$O/merge_config.log")
# docs 7.9 (initramfs devtmpfs), 9.1 (VT + fbcon on HDMI)
"$K/scripts/config" --file "$O/.config" -e DEVTMPFS -e DEVTMPFS_MOUNT \
    -e VT -e CONSOLE_TRANSLATIONS -e VT_CONSOLE -e HW_CONSOLE -e VT_HW_CONSOLE_BINDING -e DUMMY_CONSOLE \
    -e FRAMEBUFFER_CONSOLE -e FRAMEBUFFER_CONSOLE_DETECT_PRIMARY -e FONT_8x8
$MK olddefconfig > /dev/null
echo "=m: $(grep -c '=m$' "$O/.config")"

# 3. build
$MK -j"$JOBS" Image modules dtbs
cat "$O/include/config/kernel.release"
ls -l "$O/arch/arm64/boot/Image" "$O/arch/arm64/boot/dts/exynos/s5e3830.dtb" \
    "$O/arch/arm64/boot/dts/exynos/board/erd/s5e3830-erd3830.dtbo"
echo "modules: $(wc -l < "$O/modules.order")"
