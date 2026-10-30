# Caihong Ubuntu 22.04 — OnePlus Pad Pro (SM8650) Linux port

Ubuntu Server 22.04 LTS (arm64) for the OnePlus Pad Pro, codename **caihong**
(Snapdragon 8 Gen 3 / SM8650, Adreno 750, 3000×2120 panel).

This repository is a distribution port built on top of
[`osilvfe/caihong-linux-rootfs`](https://github.com/osilvfe/caihong-linux-rootfs):
it keeps that project's **validated kernel, device tree, firmware and board
services**, and replaces the Arch Linux ARM user space with a real Ubuntu Jammy
user space built from `ubuntu-ports`.

Nothing here modifies the upstream Arch/Armada build paths; the port lives in
`config/ubuntu.env`, `rootfs/ubuntu/`, `scripts/*ubuntu*`, `tools/bootimg_v2.py`
and `docs/`.

---

## Status (verified on hardware)

Booted on a real OPD2404 (serial `67ab95c8`), single-system install on the
`userdata` partition, slot B.

| Feature | Result |
| --- | --- |
| Ubuntu 22.04 boot to `caihong login:` | **PASS** |
| Internal panel, 3000×2120 (`card0-DSI-1 connected`) | **PASS** |
| Backlight (`ktz8866`, 0–2047, runtime changes) | **PASS** |
| Battery: 50 %, Charging, 3.825 V, −1.37 A, 32.0 °C, health | **PASS** |
| USB-C charging (battmgr + UCSI + SC8547 charge pumps) | **PASS** |
| GPU: `kmscube`, `renderer: FD750`, GPU 231→500 MHz | **PASS** (needs Mesa 24.3.4) |
| Vulkan: `Turnip Adreno (TM) 750`, Vulkan 1.3.296 | **PASS** |
| Thermal zones / cpufreq (`ondemand`, 2.27 GHz cap) | **PASS** |
| Wi-Fi (ath12k + WCN7850), DHCP, SSH | **PASS** |
| USB-C device mode (NCM gadget as a keyboard-free console channel) | **PASS** |
| Bluetooth | **FAIL** — `hci0` stuck `DOWN RAW`, QCA firmware not loading |
| USB host / hub / OTG | not tested — the port was in device role |
| DisplayPort alt mode | not tested — no dock available |
| Touch, stylus, Pogo keyboard, suspend | not tested |
| Sensors (SSC) | **unavailable** — prebuilt payload needs glibc 2.38, Jammy has 2.35 |
| Camera | not ported |

Full evidence, command by command: [`docs/DEVICE-TEST-2026-10-30.zh-CN.md`](docs/DEVICE-TEST-2026-10-30.zh-CN.md).
Support matrix with kernel-config proof: [`docs/HARDWARE-SUPPORT.zh-CN.md`](docs/HARDWARE-SUPPORT.zh-CN.md).

---

## Artifacts

Build with `scripts/build-image.sh` (see [`docs/BUILD.zh-CN.md`](docs/BUILD.zh-CN.md)):

```
caihong-ubuntu22.04-jammy-boot-linux.img        # dual boot, root=PARTLABEL=linux
caihong-ubuntu22.04-jammy-boot-userdata.img     # single system, root=PARTLABEL=userdata
caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst
caihong-ubuntu22.04-rootfs-userdata.ext4.sparse.img.zst
caihong-ubuntu22.04-*-SHA256SUMS, *-manifest.env
```

Prebuilt images and the Mesa bundle are attached to the GitHub release.

**Not flashed by any script.** `scripts/install-dualboot.sh` is a dry run unless
`--apply` is given; it refuses unknown devices, refuses to guess a slot, checks
the image against the real partition size, and never touches the partition
table. Read [`docs/INSTALL.zh-CN.md`](docs/INSTALL.zh-CN.md) first — the
single-system variant erases all Android data.

---

## How it works

* **Boot image**: Android boot image v2 with the kernel `Image` and the Caihong
  DTB, **no ramdisk**. `tools/bootimg_v2.py` reimplements the packer without
  dependencies and reproduces the upstream release layout byte for byte (only the
  `id` field differs; upstream leaves it stale).
* **No initramfs** because the kernel is built with `CONFIG_EXT4_FS=y`,
  `CONFIG_SCSI_UFSHCD=y` and `CONFIG_SCSI_UFS_QCOM=y`. The build asserts this by
  decoding the kernel's embedded kconfig (`CONFIG_IKCONFIG=y`) and failing if a
  required option is missing.
* **Ubuntu user space**: `debootstrap` from `ubuntu-ports` (arm64 is not on
  `archive.ubuntu.com`), an explicit package list (no `linux-image`, no
  `initramfs-tools`, no generic `linux-firmware`), then the board overlay.
* **GPU**: Ubuntu's Mesa 23.2.1 segfaults on Adreno 750 inside the freedreno
  kgsl backend; `scripts/install-caihong-mesa.sh` installs a Mesa 24.3.4 build
  (recipe in `scripts/build-caihong-mesa.sh`) that works.

---

## Two host-side gotchas

* `fastboot getvar product` answers `pineapple` (the SoC codename), not
  `caihong` — the installer uses an allowlist.
* USB-C networking uses CDC-NCM (Windows 11 24H2 removed the RNDIS driver). On
  Windows, disable the adapter's TCP/UDP checksum offload or ICMP works while all
  TCP connections time out.

---

## License

Port scripts and documentation: **GPL-2.0-only**, same as upstream.
Device firmware is vendor-licensed and is *not* in this repository — see
[THIRD-PARTY.md](THIRD-PARTY.md).
