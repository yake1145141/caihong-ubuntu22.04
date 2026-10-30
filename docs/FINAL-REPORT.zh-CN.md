# 最终状态报告：一加平板 Pro（Caihong）Ubuntu Server 22.04 LTS ARM64

报告日期：2026-10-30
参考仓库：`osilvfe/caihong-linux-rootfs` @ `4685dc8da324d1ca99c44177e8bc5922a1de9ca2`
本次移植提交：`8e197eb`（主体）、`664e5c4`（SSH 主机密钥修复等）

---

## 1. 结论摘要

| 阶段 | 结果 |
| --- | --- |
| 仓库与硬件分析 | 完成（内核内嵌 kconfig、DTB、boot image 布局全部实读，未依赖型号推断） |
| Ubuntu 22.04 ARM64 用户空间构建 | **完成**，`debootstrap` + `ubuntu-ports`，354 个包 |
| Android boot image v2 打包 | **完成**，与参考镜像布局字节级一致（仅 `id` 字段不同） |
| 可安装 sparse ext4 镜像 | **完成**，两个布局各一份，带 SHA-256 与 manifest |
| 结构/一致性校验 | **完成**：67 项断言通过，0 失败 |
| **模拟启动测试（QEMU）** | **完成**：用**发布的内核 Image + 发布的 rootfs 镜像**在 GPT 名为 `linux` 的
分区上启动，到达 `caihong login:`，sshd 正常启动 |
| **真机验证** | **未进行**（本环境无设备）。P0 项目一律标注为待真机验收 |

一句话：**这套镜像在结构和启动流程上已经被证明能进入 Ubuntu 22.04 的登录终端；
但内屏、电池、充电、USB-C、GPU 的真实行为必须在设备上确认。**

---

## 2. 交付物与校验值

存放于 `F:\1+\arch\caihong-ubuntu-release\`（服务器上另存于
`/root/data/caihong-ubuntu-work/caihong-linux-rootfs/release/`）。

| 文件 | 大小 | SHA-256 |
| --- | --- | --- |
| `caihong-ubuntu22.04-jammy-boot-linux.img` | 44 MiB | `9bfca3b90acf97ed55c04fdbc4595e420d55216a5f5feed99918fc7294620ec1` |
| `caihong-ubuntu22.04-jammy-boot-userdata.img` | 44 MiB | `6e0bed232a6fffd6870e79d7e064e8931e8d608856551298fbc7ecf175fe3fed` |
| `caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst` | 222 MiB | `95aee098faba35ff0de586561765938f03ee3e5f3cdf9e4ca9bdeddec7f70d4d` |
| `caihong-ubuntu22.04-rootfs-userdata.ext4.sparse.img.zst` | 222 MiB | `3b041b15f76c742f0935d572b79f209bc927d8386b34fa1d637d72cc321f90ac` |

镜像逻辑大小 2304 MiB，rootfs 实际占用 746 MiB（782,499,840 B），压缩后 222 MiB
（未超 2 GiB，未分片）。

**已在 Windows 主机上重新计算并比对全部 SHA-256：全部一致。**

来源与版本清单：

| 组件 | 版本/摘要 |
| --- | --- |
| 内核 | `7.3.0-g77f2f22ff4f9`（参考 Release 的 `linux-caihong` 包，未重建） |
| Image | 45,988,352 B，`f5f187520e52d297f884efe290dc3a265b2da15fbaccaa9b53e0f3f33631fbf0` |
| DTB | 146,295 B，`b92da2dd6f16fffe6f7241ce2ebc7758b9b87f5b4d63e1d2b997e4cc2072f4c8`（`Oneplus Pad Pro`, `oneplus,caihong qcom,sm8650`） |
| 模块 | 134 个 `.ko` + 804 个 builtin，`depmod` 重新生成依赖 |
| 固件 | 参考仓库 `firmware/` 57 MB（SHA256SUMS 校验通过）+ 生成的 AudioReach topology |
| 用户空间 | Ubuntu 22.04.5，systemd 249.11、glibc 2.35、OpenSSH 8.9p1、NetworkManager 1.36.6、BlueZ 5.64、Mesa 23.2.1 |

---

## 3. 已实现的功能与代码位置

| 功能 | 实现位置 | 证据级别 |
| --- | --- | --- |
| Ubuntu 22.04 arm64 rootfs（debootstrap，交叉 qemu） | `scripts/build-ubuntu-rootfs.sh` | 构建通过 + 镜像内 `/etc/os-release` 校验 |
| 内核/DTB/模块准备与断言 | `scripts/prepare-caihong-kernel.sh` | 构建通过（10 项 kconfig 断言） |
| boot image v2 打包（无依赖） | `tools/bootimg_v2.py`、`scripts/package-ubuntu-boot.sh` | 与参考镜像字节级比对 |
| sparse ext4 镜像生成 | `scripts/build-ubuntu-image.sh` | `e2fsck -fn` + `simg2img` 回读 |
| 结构校验（67 项） | `scripts/verify-ubuntu-image.sh`、`scripts/verify-image.sh` | 全绿 |
| glibc 兼容性判定 | `scripts/check-aarch64-glibc.sh` | 实测拦截 GLIBC_2.38 载荷 |
| 登录终端 + SSH | 镜像内 `getty@tty1`、`ssh.service`、`ssh.service.d/10-caihong-host-keys.conf` | **QEMU 实测到 login 提示** |
| 电池状态读取（不伪造） | `rootfs/ubuntu/usr/local/sbin/caihong-battery` | 读 `/sys/class/power_supply`；真机待测 |
| 首次启动扩容（与分区标签无关） | `rootfs/ubuntu/usr/local/sbin/caihong-grow-rootfs` + service | 逻辑审阅；真机待测 |
| 板级服务（笔、热点、硬件 MAC、A/B 槽） | 复用参考 `rootfs/archlinuxarm` 脚本与 systemd 单元 | 已装入镜像 |
| 安装/回退（默认 dry-run） | `scripts/install-dualboot.sh` | 逻辑审阅，未对真机执行 |
| 真机诊断归档 | `scripts/collect-debug.sh` | 可在设备上运行 |
| CI | `.github/workflows/ubuntu-image.yml` | 未在 GitHub 实跑（需内核包资产） |

---

## 4. 关键工程发现（均有实证）

1. **参考 boot image 的真实布局**：header v2、`header_size=1660`、`dtb_size=146295`、
   `dtb_addr=0x04000000`、`ramdisk_size=0`。`id` 字段是**陈旧的**（linux 与 userdata
   两个不同 cmdline 的镜像共享同一个 `id`），说明发布流程在打包后改写过 header 而没重算
   `id`。本移植的打包器复现该布局：除 `id` 外**字节完全一致**。
2. **不需要 initramfs 的原因不是猜测**：从 `Image` 里解出内嵌 kconfig
   （`CONFIG_IKCONFIG=y`，10284 行，见 `kernel/caihong-kconfig-7.3.0.txt`）证明
   `EXT4_FS=y`、`SCSI_UFSHCD=y`、`SCSI_UFS_QCOM=y`。
3. **内屏文本控制台有内核保证**：`DRM_FBDEV_EMULATION=y`、`FRAMEBUFFER_CONSOLE=y`、
   `VT_CONSOLE=y`，面板驱动 `DRM_PANEL_NOVATEK_NT36532=y` 内置，背光 `KTZ8866=y`。
4. **Ubuntu 22.04 没有 `adbd`**：jammy 只有 `adb`/`fastboot`/`mkbootimg`；
   Debian bullseye 也没有 `adbd`，bookworm/trixie 的版本需要 GLIBC_2.36~2.38，
   jammy 只有 2.35。因此镜像不提供 adb 设备端调试，服务因
   `ConditionPathExists=/usr/bin/adbd` 不会启动。**这是有证据的“做不到”，不是遗漏。**
5. **传感器（SSC）不可用**：参考 Release 的 `iio-sensor-proxy`、`libhexagonrpc.so.0.5`
   需要 `GLIBC_2.38`；Ubuntu 的 `iio-sensor-proxy 3.3` 的依赖里**没有 libssc**
   （SSC 后端未编译）。因此两者无法拼接，构建时自动跳过并记录
   `ssc=incompatible-glibc`。
6. **GPU 用户空间**：发布的 `kgsl_dri.so`、`msm_dri.so`、`libvulkan_freedreno.so`
   的设备表中都含 `FD730`（Adreno 750），即 Mesa 23.2.1 会识别该 GPU；
   但 a7xx 的 Vulkan 在该版本仍属早期实现，稳定性必须真机验证。
7. **QEMU 启动测试抓到一个真实缺陷**：镜像为了安全性不预置 SSH 主机密钥，而
   Ubuntu 的 `ssh.service` 先执行 `sshd -t`，无密钥即失败。已用
   `ssh.service.d/10-caihong-host-keys.conf`（`ssh-keygen -A` 先于校验）修复，
   复测确认 `Started OpenBSD Secure Shell server`。

---

## 5. 构建环境与完整命令

- 主机：Ubuntu 22.04 x86_64（阿里云 8 核 / 15 GiB / 428 GiB `/root/data`），
  root 权限，`qemu-aarch64` binfmt 已注册。
- 依赖：`debootstrap qemu-user-static binfmt-support e2fsprogs
  android-sdk-libsparse-utils libarchive-tools zstd python3 kmod
  device-tree-compiler m4 alsa-utils git`

```sh
# 0) 放入参考 Release 的内核包
cp linux-caihong-7.3.0.g77f2f22ff4f9-1-aarch64.pkg.tar.zst release/

# 1) 内核/DTB/模块/固件校验与准备
sudo scripts/prepare-caihong-kernel.sh

# 2) Ubuntu Jammy arm64 用户空间（约 35 分钟，qemu 交叉）
sudo scripts/build-ubuntu-rootfs.sh build/rootfs

# 3) boot 镜像 + 两种根分区布局的 sparse 镜像 + 校验（约 4 分钟）
sudo scripts/build-image.sh --skip-rootfs --variant both
```

迭代时可用 `RESUME=1` 跳过 debootstrap（本次调试全程使用）。

---

## 6. 实际执行过的测试与结果

| # | 命令/方法 | 结果 |
| --- | --- | --- |
| 1 | 用自研打包器解包再打包参考 `caihong-boot-linux-*.img`，逐字节 diff | 仅 32B `id` 不同，其余完全一致 |
| 2 | `prepare-caihong-kernel.sh` 的 kconfig 断言 | 10 项全部满足 |
| 3 | `verify-ubuntu-image.sh`（rootfs + 2 boot + 2 image） | **67 passed / 0 failed / 8 skipped** |
| 4 | `e2fsck -fn` 两个原始镜像 | 通过 |
| 5 | `simg2img` 回读两个 sparse 镜像 | 通过 |
| 6 | `debugfs` 读镜像内 `/usr/lib/os-release`、`/etc/fstab`、systemd、模块树 | 通过 |
| 7 | Windows 端重新计算 4 个产物的 SHA-256 | 全部一致 |
| 8 | **QEMU 启动测试**：`-M virt -cpu max -kernel build/kernel/Image`，磁盘为 GPT 命名 `linux` 的分区 + 发布镜像，cmdline `root=PARTLABEL=linux` | 内核启动 → 挂载 ext4 → systemd → `Reached target Login Prompts` → `caihong login:`；sshd 启动成功 |
| 9 | 上述启动中唯一失败单元 | `caihong-hardware-mac.service`（QEMU 无高通 NVRAM/WLAN，属预期） |

未能执行：所有需要真实硬件的行为（内屏点亮、亮度、电池数值、USB-C 充电/OTG/Hub、
GPU 渲染、Wi-Fi/蓝牙、休眠恢复、DP Alt Mode）。

---

## 7. 未实现 / 受限项与下一步

| 项目 | 阻碍 | 下一步 |
| --- | --- | --- |
| 传感器（SSC） | 预编译件需 glibc 2.38；Ubuntu 的 iio-sensor-proxy 无 libssc | 在 jammy 容器内从源构建 `libhexagonrpc` + `libssc` + `iio-sensor-proxy`（参考 VERSION `hexagonrpc 40e5041`） |
| adbd | jammy 无 adbd 包，替代件需更高 glibc | 从 AOSP `packages/modules/adb` 交叉编译，或放弃（用 tty1/USB 网卡 + SSH） |
| 摄像头 | 参考项目的自建 libcamera/Camera ICP 栈未移植 | 复用其 `install-caihong-libcamera-rootfs.sh` 思路，在 jammy 上重建 libcamera |
| Vulkan on a730 | Mesa 23.2 的 a7xx 早期实现 | 可选：在 jammy 上交叉构建 Mesa 24.x 提供 Turnip a7xx |
| 144 Hz | 与参考项目一致，需要模式切换 | 真机验证后再定 |
| 私有快充功率 | 需要真机与温度/电流实测 | 先验证常规 USB-C 充电安全边界 |
| NPU/VPU 运行时 | 载荷体积大、libdir 布局差异 | 作为可选组件单独安装 |
| CI | 未在 GitHub 实跑 | 需要内核包资产 URL/secret |

---

## 8. 真机刷入、启动与回退

详见 `docs/INSTALL.zh-CN.md`。要点：

```sh
# 只读检查
fastboot getvar product              # 必须为 caihong
fastboot getvar current-slot
scripts/install-dualboot.sh --variant linux --slot b --list
scripts/install-dualboot.sh --variant linux --slot b        # dry-run，打印全部命令

# 备份 boot_b / dtbo_b / vbmeta（见文档第 4 节）后执行
scripts/install-dualboot.sh --variant linux --slot b --vbmeta vbmeta.img --apply

# 回退
fastboot --set-active=a
fastboot flash boot_b backup-boot_b.img
fastboot flash dtbo_b backup-dtbo_b.img
```

首次启动：内屏应出现内核日志与 `caihong login:`（默认 `root/caihong`、
`caihong/caihong`，登录后立即 `passwd`）。首次启动会执行扩容，比后续启动慢。

---

## 9. 风险清单

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 刷错槽位 / 未备份 boot | 该槽 Android 无法启动 | 默认 dry-run，要求输入确认串，文档给出回退命令 |
| `vbmeta` 不匹配 | bootloader 拒绝启动 | 必须用同版本原厂 `vbmeta.img` |
| 单系统变体写 `userdata` | **Android 数据全部丢失** | 明确警告 + 独立参数，默认不启用 |
| 分区表被改 | 可能变砖 | 本工具**不修改分区表**，只写既有分区 |
| 首次启动黑屏 | 无法使用 | 预留 USB-C 网卡 + SSH 路径；`collect-debug.sh` 取证 |
| 充电异常 | 过热/损伤 | 只用内核既有充电控制，不绕过温度限流；不宣称最高功率 |
| `mkfs.ext4 -d` 丢 xattr | 非 root 使用 `ping` 等可能失败 | 可在真机上用 `getcap` 抽查（待办） |

---

## 10. 许可证

本移植新增的脚本与文档沿用参考项目的 `GPL-2.0-only`。随附固件仍受厂商条款约束，
来源记录见 `firmware/SOURCE.md` 与 `firmware/SHA256SUMS`；Ubuntu 软件包遵循各自许可证。
