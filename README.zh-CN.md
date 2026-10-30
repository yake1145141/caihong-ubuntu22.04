# 一加平板 Pro（Caihong）Ubuntu Server 22.04 LTS ARM64 移植

本目录是在参考项目 [`osilvfe/caihong-linux-rootfs`](https://github.com/osilvfe/caihong-linux-rootfs)
（Arch Linux ARM + mainline Linux）之上建立的 **Ubuntu 22.04 LTS（Jammy）arm64**
移植。目标不是把 Arch 镜像改个名字，而是用 Ubuntu 官方 `ubuntu-ports` 用户空间
重新构建系统，并且只复用参考项目中经过真机验证的**内核、设备树、模块、固件和
板级服务**。

- 参考仓库提交：`4685dc8da324d1ca99c44177e8bc5922a1de9ca2`（2026-10-27）
- 内核：`7.3.0-g77f2f22ff4f9`（来自 Release 中的 `linux-caihong` 包，未重建）
- 启动方式：Android boot image v2，仅含 `Image` + Caihong DTB，**无 ramdisk**
- 根文件系统：ext4，`root=PARTLABEL=linux`（双系统）或 `userdata`（单系统）

> 说明：本移植工作在参考仓库的工作树中新增了 `config/ubuntu.env`、
> `rootfs/ubuntu/`、`scripts/*ubuntu*`、`tools/bootimg_v2.py` 等文件，
> 未改动参考项目的 Arch/Armada 构建路径。

## 1. 当前状态（一句话版本）

| 阶段 | 状态 |
| --- | --- |
| 源码/仓库分析 | 完成，见 [docs/HARDWARE-SUPPORT.zh-CN.md](docs/HARDWARE-SUPPORT.zh-CN.md) |
| 内核/设备树/模块/固件复用与校验 | 完成，可重复执行 |
| Ubuntu Jammy ARM64 rootfs 构建 | 完成，`debootstrap` + 官方源 |
| 启动镜像打包 | 完成，与参考镜像布局字节级兼容（仅 `id` 字段不同） |
| 可安装 sparse ext4 镜像 | 完成，含 SHA-256、manifest、自动化校验 |
| 结构校验 | **67 项断言全部通过** |
| 模拟启动（QEMU，用发布的内核与镜像） | **完成**：到 `caihong login:`，sshd 正常启动 |
| **真机验证** | **未进行**（当前环境没有设备）。所有 P0 项目均标注为“待真机验证” |

任何“已通过”的表述都指构建产物层面的验证，不等同于真机验收。

## 2. 目录与脚本

```
config/ubuntu.env                     # 全部版本/摘要/镜像源固定值
config/caihong-ubuntu-cmdline-*.txt   # 两种根分区布局的内核命令行
rootfs/ubuntu/                        # Ubuntu 专用板级覆盖层
  etc/systemd/system/caihong-*.service
  usr/local/sbin/caihong-grow-rootfs  # 首启动扩容（与分区标签无关）
  usr/local/sbin/caihong-adbd-run     # adbd 监督逻辑（Jammy 无 adbd 包，默认不启用）
  usr/local/sbin/caihong-battery      # 直接读 /sys/class/power_supply
scripts/prepare-caihong-kernel.sh     # 校验内核包、抽 Image/DTB、还原 kconfig、depmod
scripts/build-ubuntu-rootfs.sh        # debootstrap 构建 Ubuntu 22.04 arm64
scripts/build-ubuntu-image.sh         # 生成 Android sparse ext4 镜像
scripts/package-ubuntu-boot.sh        # 生成两种 boot.img
scripts/build-image.sh                # 一键全流程
scripts/verify-ubuntu-image.sh        # 结构与兼容性校验
scripts/install-dualboot.sh           # 安装/刷写（默认 dry-run）
scripts/collect-debug.sh              # 真机诊断信息打包
scripts/check-aarch64-glibc.sh        # 预编译 aarch64 二进制的 glibc 兼容性检查
tools/bootimg_v2.py                   # 无依赖的 Android boot image v2 打包/解包
kernel/caihong-kconfig-7.3.0.txt      # 从 Image 中还原的真实内核配置（证据）
```

## 3. 构建

### 3.1 主机要求

- Ubuntu 22.04（x86_64 交叉构建或原生 aarch64 均可），root 权限
- 依赖：`debootstrap qemu-user-static binfmt-support e2fsprogs
  android-sdk-libsparse-utils zstd bsdtar python3 kmod device-tree-compiler git`
- Ubuntu arm64 软件包来自 `ubuntu-ports`（`archive.ubuntu.com` 不含 arm64）

```sh
sudo apt-get install -y debootstrap qemu-user-static binfmt-support e2fsprogs \
  android-sdk-libsparse-utils zstd libarchive-tools python3 kmod \
  device-tree-compiler git

sudo scripts/checkout-dependencies.sh          # 取 qbootctl 源码（可选，用于 A/B 槽工具）
sudo scripts/prepare-caihong-kernel.sh         # 需要 release/linux-caihong-*.pkg.tar.zst
sudo scripts/build-ubuntu-rootfs.sh            # 约 20-40 分钟（qemu 交叉）
sudo scripts/package-ubuntu-boot.sh
sudo scripts/build-ubuntu-image.sh
sudo scripts/verify-ubuntu-image.sh --rootfs build/rootfs \
  --boot release/caihong-ubuntu22.04-jammy-boot-linux.img \
  --image release/caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img
```

或一条命令：

```sh
sudo scripts/build-image.sh --variant both
```

### 3.2 产物

```
release/caihong-ubuntu22.04-jammy-boot-linux.img        # 双系统 boot
release/caihong-ubuntu22.04-jammy-boot-userdata.img     # 单系统 boot
release/caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst[.part-NN]
release/caihong-ubuntu22.04-rootfs-userdata.ext4.sparse.img.zst[.part-NN]
release/caihong-ubuntu22.04-*-SHA256SUMS
release/caihong-ubuntu22.04-*-manifest.env
```

实际文件名与校验值见构建输出和 `release/` 目录。

## 4. 安装

完整步骤（含分区、备份、回退）见 **[docs/INSTALL.zh-CN.md](docs/INSTALL.zh-CN.md)**。
摘要：

```sh
# 1) 只读检查：列出将要执行的操作，不写设备
scripts/install-dualboot.sh --variant linux --slot b --list
scripts/install-dualboot.sh --variant linux --slot b

# 2) 确认后执行（需要已解锁 bootloader、关闭 AVB）
scripts/install-dualboot.sh --variant linux --slot b --vbmeta vbmeta.img --apply
```

脚本会拒绝非 `caihong` 设备、拒绝未指定的槽位、校验镜像逻辑大小不超过目标分区，
并且只擦除目标槽的 `dtbo_<slot>`，不碰分区表和 `userdata`。

默认登录：`root/caihong`、`caihong/caihong`（首次登录后必须修改）。

## 5. 已知限制（重要）

1. **未做真机验证**。P0 项目（内屏、电池、充电、USB Hub、GPU）都需要按
   `scripts/collect-debug.sh` 的结果逐项确认。
2. **触摸传感器子系统（SSC）不可用**：参考 Release 中的 `iio-sensor-proxy` /
   `libhexagonrpc` 需要 `GLIBC_2.38`，Jammy 提供 `2.35`，因此构建时自动跳过并
   在 `/etc/caihong-rootfs-build-info` 中记录 `ssc=incompatible-glibc`。
3. **GPU 用户空间是 Mesa 23.2.1**：实测随镜像发布的 `kgsl_dri.so` 与
   `libvulkan_freedreno.so` 都列出了 `FD730`（Adreno 750），因此驱动会识别设备；
   但 23.2 的 a7xx Vulkan 仍属早期实现，能否稳定渲染必须在真机上用
   `kmscube` / `glmark2-es2` / `vulkaninfo` 验证。OpenGL ES 是主要验收路径。
4. **摄像头未移植**：参考项目自建 libcamera 与 Camera ICP/BPS 栈，本移植未包含。
5. **144 Hz 未验证**：与参考项目一致，仍需黑屏模式切换。
6. **私有快充协议**：仅保证常规 USB-C 充电链路；PPS/VOOC 依赖内核已带驱动，
   但功率上限与温度限流必须真机实测后才能宣称。
7. **没有 adbd**：Ubuntu 22.04 不提供 `adbd` 包；Debian 的 `adbd` 需要
   `GLIBC_2.36~2.38`，Jammy 只有 2.35，无法加载。`caihong-adbd.service` 因
   `ConditionPathExists=/usr/bin/adbd` 保持不启动。启动阶段的调试通道是内屏
   tty1 控制台，或 USB-C 网卡 + SSH。

详细结论、构建日志摘要、测试记录与风险清单见
**[docs/FINAL-REPORT.zh-CN.md](docs/FINAL-REPORT.zh-CN.md)**。

## 6. 许可

脚本与工具沿用参考项目的 `GPL-2.0-only`。随附固件仍受厂商条款约束，来源记录见
`firmware/SOURCE.md` 与 `firmware/SHA256SUMS`。
