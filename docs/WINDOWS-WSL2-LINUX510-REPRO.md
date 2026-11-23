# Windows 11 + WSL2에서 벤더 5.10 + Debian 부팅 재현 (경로 B: LK 유지)

- 작성: 2026-11-23, 학생 Fork `sophieevlsi-ai/e85096-dvs-bringup`, 브랜치 `feature/windows-wsl2-linux510`
- 기준: upstream `e514a95`(2026-11-14), Linaro 커널 `android-exynos-5.10-linaro` `3b6b9ca5`
- 결과 요약: **Mac(Apple Silicon Docker)을 쓰지 않고 Windows 11 + WSL2 Ubuntu 24.04만으로 커널·모듈·boot.img·Debian rootfs를 빌드했다. 우리 E850-96에 기록해 Linux 5.10 + Debian 12로 부팅하고 root 셸까지 확인했다.** DVS 센서는 아직 연결하지 않았다(MIPI/CSIS 수신 미검증).

관찰한 사실과 검증하지 않은 것을 구분해 적는다. 백업 이미지, 기기 고유 파티션(efs 등), 센서 매뉴얼 내용은 이 저장소에 넣지 않는다.

## 1. 환경

| 항목 | 값 |
|---|---|
| PC | Windows 11 Education 26200, x86-64. 관리자 권한은 드라이버 설치(Zadig)에만 사용 |
| WSL2 | Ubuntu 24.04.3, `systemd=true`, binfmt `qemu-aarch64`(flag F) |
| 컴파일러 | AOSP `clang-r450784e` = Android clang 14.0.7 (8508608). x86 리눅스용이라 WSL2에서 네이티브로 실행 |
| Windows 도구 | Python 3.11 + pyserial / pyusb / libusb-package, Android platform-tools(adb), Zadig(WinUSB) |
| 보드 | E850-96, Android 10 eng `full_erd850` (eng.joe.20221017), LK `Dec 13 2022` |
| UART | FT232RL 어댑터 1.8 V, J5 1(GND)/11(TX)/13(RX), 115200 8N1 |

## 2. 결과 (2026-11-23)

| 단계 | 결과 |
|---|---|
| 커널 | `5.10.157-g3b6b9ca51034-dirty`, `Image` 46,926,148 B(docs `E85096-LINUX510-BOOT.md` 1장의 Image와 같은 크기), 모듈 141개. `build-kernel-wsl.sh`를 다시 실행해도 같은 Image(SHA-256 같음) |
| 외부 모듈 | `is-cis-s5krc1s.ko`, `dvs-power`, `e850-vbus`, `e850-cpuhp`, `csis-irqstat`, `csis-peek`, `cpu-pmu-enable`, `is-cis-ov5647`, `e850-fbpal` 모두 빌드 |
| boot.img | 64,329,728 B (header v2: Image + busybox initramfs + merged DTB) |
| rootfs | Debian 12 arm64, `rootfs.simg` 431,199,352 B → `resparse.py` 후 431,200,008 B |
| 기록 | `fbmini.py flash boot`(2.8 s), `flash userdata`(58 s, FILL 32 MiB 단위로 끝까지 처리) |
| 부팅 | `[init] modules.stage1: 18 ok, 0 failed` → `switching to /dev/mmcblk0p24` → systemd. 패닉·Oops 0 |
| 로그인 | Windows에 `USB 직렬 장치(COM4)`(VID 1d6b PID 0104). `uname -a` = `Linux e850-96 5.10.157-g3b6b9ca51034-dirty #2 SMP PREEMPT … aarch64`, Debian 12, 8 CPU, `systemctl is-system-running` = `running`, `/dev/video102` 있음 |
| 미확인 | HDMI 화면, Wi-Fi 접속, DVS(센서 미연결) |

## 3. Mac 흐름과 다른 점, 그리고 고친 것

| # | 증상 | 원인 | 대응 (이 브랜치) |
|---|---|---|---|
| 1 | `s5krc1s-pablo/apply.sh` rc=1 | 공개 Linaro 트리에 `SENSOR_NAME_S5KRC1S`, `CAMERA_CIS_S5KRC1S_OBJ`, Makefile 줄이 없다(41 `S5K5E9` 다음이 43). 스크립트는 이미 있다고 가정하고 `grep -q`만 한다 | `apply.sh`가 ov5647과 같은 방식으로 42번·Kconfig(`default n`)·Makefile 줄을 추가 |
| 2 | 설정에 `=m` 3개뿐 | `merge_config.sh`가 끝에서 부르는 `make alldefconfig`에 `ARCH=arm64`가 없으면 x86 기준으로 정리 | 환경 변수 `ARCH/LLVM/CROSS_COMPILE`를 export (`build-kernel-wsl.sh`) |
| 3 | `link-vmlinux.sh: python: not found` | Ubuntu 24.04에는 `python`이 없음 | python → python3 임시 링크를 PATH 앞에 (sudo 불필요) |
| 4 | `fdtoverlay … FDT_ERR_NOTFOUND` | `s5e3830.dts`의 `//#include "s5e3830-dpu.dtsi"`로 `decon_f/dsim_0/panel_0` 라벨이 없음. docs 8.2는 손으로 고쳤지만 `e850-hdmi/apply.sh`에는 그 단계가 없다 | `e850-hdmi/apply.sh`에 주석 해제 추가 |
| 5 | initramfs에 x86 busybox가 들어갈 위험 | `build-bootimg.sh`는 arm64 컨테이너의 `/bin/busybox`를 복사 | `build-bootimg-wsl.sh`: Ubuntu jammy `busybox-static` arm64 패키지를 `BUSYBOX=`로 지정, `fakeroot`, `aarch64-linux-gnu-strip` |
| 6 | apt `NO_PUBKEY` | Ubuntu에는 Debian 저장소 키가 없음 | `apt-get download debian-archive-keyring`(Ubuntu가 서명 확인) → `KEYRING=` |
| 7 | 네임스페이스 root가 홈 디렉터리를 못 읽음 | rootless `mmdebstrap --mode=unshare`의 root는 보조 uid, 홈은 0750 | 입력을 `/tmp` 임시 디렉터리에 모은 뒤 hook이 그것만 사용 (`build-rootfs-wsl.sh`, `rootfs-customize.sh`) |
| 8 | `mke2fs -d rootfs.tar`: Not a directory | Ubuntu 24.04 e2fsprogs 1.47.0은 tar 입력 미지원(1.47.1부터) | `fakeroot`로 풀고 디렉터리로 `mke2fs -d`. 파일 capability xattr(ping 등)은 옮겨지지 않음 |
| 9 | Windows `fastboot.exe devices` 빈 출력 | fastboot.exe는 Google AdbWinApi 드라이버 장치만 찾음. Zadig WinUSB는 보이지 않음 | `tools/host/windows/fbmini.py`(fbmini.c의 pyusb 이식) |

## 4. J1(micro-USB) ADB가 안 보이던 원인

- 중간고사 부팅 로그: `dwc3_get_properties: dr_mode:1`(HOST), xHCI 등록. Android에서 `/sys/class/udc`가 비어 있었다.
- 이 보드의 dtbo(p5)는 Linaro `dtbo-host.img`와 바이트 단위로 같았다(DT 테이블 199,092 B). Linaro `dtbo-peri.img`와의 차이는 3개 항목의 `dr_mode` 한 줄뿐이다.
- UART root 셸(eng 빌드의 `console:/ $` + `su 0`)로 dtbo-peri를 p5에 기록했다. 재부팅 후 `dr_mode:2`, Windows에 `SAMSUNG Android ADB Interface`가 나타났다. 원본 dtbo는 백업해 두었다.
- 남은 문제: Android ADB의 대량 전송이 약 12~20 MB마다 끊긴다(adb 37.0.3, 33.0.3 모두). 같은 케이블과 포트에서 LK fastboot는 100 MB와 431 MB를 끊김 없이 받았다. 그래서 Android 쪽 원인일 가능성이 높다고 보지만 확정하지 않았다. 백업은 1 MiB 조각 + 해시 확인 + adbd 재시작(`adbchunkpull.py`)으로 받았다.

## 5. 재현 순서

```bash
# WSL2 Ubuntu 24.04 (sudo 필요한 것은 패키지 설치뿐)
sudo apt install -y git build-essential bc bison flex libssl-dev libelf-dev device-tree-compiler \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu cpio kmod fakeroot python3 \
  android-sdk-libsparse-utils mmdebstrap qemu-user-static binfmt-support e2fsprogs
git clone --depth 1 -b android-exynos-5.10-linaro https://gitlab.com/Linaro/96boards/e850-96/kernel.git ~/e850/kernel
# clang-r450784e: platform/prebuilts/clang/host/linux-x86, branch master-kernel-build-2022, +archive/clang-r450784e.tar.gz
K=~/e850/kernel O=~/e850/out CLANG=~/e850/clang-r450784e tools/linux510/build-kernel-wsl.sh
K=~/e850/kernel O=~/e850/out PREBUILTS=<dir with clang/host/linux-x86/clang-r450784e> tools/linux510/build-modules-wsl.sh
O=~/e850/out OUT=~/e850/boot-out BUSYBOX=<arm64 busybox-static> BACKUP=<stock boot .img.gz> \
  tools/linux510/build-bootimg-wsl.sh root=PARTLABEL=userdata
python3 tools/linux510/wifi-fw-linaro.py ~/e850/rootfs-out/wifi-a13.tgz
KEYRING=<debian-archive-keyring.gpg> O=~/e850/out OUT=~/e850/rootfs-out tools/linux510/build-rootfs-wsl.sh
python3 tools/linux510/resparse.py ~/e850/rootfs-out/rootfs.simg ~/e850/rootfs-out/rootfs-split.simg
```

```powershell
# Windows (보드 쓰기 전: 원본 boot/dtbo 등 백업, tools/host/windows/README.md 참고)
python tools\host\windows\uartsh.py "su 0 reboot bootloader"
python tools\host\windows\fbmini.py flash boot boot.img
python tools\host\windows\fbmini.py flash userdata rootfs-split.simg
python tools\host\windows\fbmini.py reboot
python tools\host\windows\uartsh.py "uname -a" --port COM4
```

되돌리기: `fbmini.py flash boot <원본 boot 백업>` → Android 10. 2026-11-23에 같은 내용 재기록 시험으로 동작을 확인했다(SHA-256 일치, `sys.boot_completed=1`).

## 6. 다음

- HDMI 화면과 Wi-Fi 확인
- 센서 없이: `is-cis-s5krc1s` 적재, 전원 시퀀스(LDO32, GPC0[2]) 로그, `/dev/video102` 열기 동작
- DVS 센서 연결 후: I²C 0x10, CSIS 수신, `dvscap.sh`, 디코더
