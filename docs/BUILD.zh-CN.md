# 构建说明（Ubuntu 22.04 ARM64 / Caihong）

## 1. 原则

1. **内核与设备树不重建**。使用参考 Release 中 `linux-caihong` 包里的 `Image`
   和 DTB，因为它们是唯一与固件、设备树、模块 ABI 一起验证过的组合。
   换内核会引入未经验证的变量，收益极小。
2. **用户空间完全来自 ubuntu-ports**。没有任何 Arch 包、没有 pacman、没有
   替换发行版标识。`/etc/os-release`、dpkg 数据库、systemd 单元均为原生 Ubuntu。
3. **启动链保持 ramdisk-less**。内核把 ext4 与 Qualcomm UFS 编进内核
   （构建时通过内嵌 kconfig 断言），因此不需要 initramfs。
4. **所有输入都可校验**：内核包、固件树、DTB、Image 都有 SHA-256，构建脚本
   在失败时返回非零并给出原因。

## 2. 主机环境

| 项目 | 要求 |
| --- | --- |
| 发行版 | Ubuntu 22.04（x86_64 交叉构建）或原生 aarch64 |
| 权限 | root（debootstrap 与文件属主） |
| 磁盘 | 约 12 GiB 临时空间（rootfs + raw 镜像 + sparse + 压缩） |
| 内存 | ≥ 4 GiB（qemu-user 下 apt 需要） |

```sh
sudo apt-get install -y --no-install-recommends \
  debootstrap qemu-user-static binfmt-support \
  e2fsprogs android-sdk-libsparse-utils libarchive-tools \
  zstd python3 kmod device-tree-compiler git curl ca-certificates

# 交叉构建必须确认 aarch64 binfmt 已注册
ls /proc/sys/fs/binfmt_misc/ | grep aarch64
```

## 3. 完整构建顺序

```sh
# 0) 取得内核包（Release 资产），放到 release/
ls release/linux-caihong-7.3.0.g77f2f22ff4f9-1-aarch64.pkg.tar.zst

# 1) 校验内核包 → 抽 Image/DTB → 还原内嵌 kconfig → 安装模块 → depmod
sudo scripts/prepare-caihong-kernel.sh

# 2) 构建 Ubuntu Jammy arm64 用户空间
sudo scripts/build-ubuntu-rootfs.sh build/rootfs

# 3) 打包两种 boot 镜像
sudo scripts/package-ubuntu-boot.sh

# 4) 生成两个布局的 sparse ext4 镜像（自动压缩、分片、校验）
sudo ROOT_PARTLABEL=linux    FORCE=1 scripts/build-ubuntu-image.sh
sudo ROOT_PARTLABEL=userdata FORCE=1 scripts/build-ubuntu-image.sh

# 5) 校验
sudo scripts/verify-ubuntu-image.sh --rootfs build/rootfs \
  --boot release/caihong-ubuntu22.04-jammy-boot-linux.img \
  --image release/caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img

# 或一条命令完成 1-5
sudo scripts/build-image.sh --variant both
```

### 迭代技巧

`build-ubuntu-rootfs.sh` 支持 `RESUME=1`：跳过 debootstrap，直接在已有树上继续
安装/配置。开发包列表时能省掉十几分钟：

```sh
sudo RESUME=1 scripts/build-ubuntu-rootfs.sh build/rootfs
```

## 4. 各步骤实际做了什么

### 4.1 `prepare-caihong-kernel.sh`

1. 校验 `linux-caihong` 包的 SHA-256（`config/ubuntu.env` 中固定）。
2. 用 `tools/bootimg_v2.py` 从包内的 `boot-linux.img` / `boot-userdata.img`
   中抽出 `Image` 与 DTB，并核对两个变体的内核一致、DTB 属于 `oneplus,caihong`。
3. 从 `Image` 中定位 `IKCFG_ST`/`IKCFG_ED`，解出**真实内核配置**并断言 Ubuntu
   镜像依赖的选项（ext4/UFS/fbdev/fbcon/VT/msm/battmgr/Type-C/DP altmode）。
4. 安装模块树到 `build/kernel/lib/modules/<release>` 并用宿主 `kmod` 重新
   `depmod`（不信任包内旧 `modules.dep`）。
5. 输出 `build/kernel/manifest.env`，供后续步骤断言。

### 4.2 `build-ubuntu-rootfs.sh`

- `debootstrap --arch=arm64 --variant=minbase jammy <mirror>`；
  x86_64 宿主先 `--foreign`，再在 `qemu-aarch64-static` 下 `--second-stage`。
- 软件源指向 `ubuntu-ports` 的 `jammy`/`jammy-updates`/`jammy-security`
  （arm64 不在 `archive.ubuntu.com` 上）。
- 显式包清单安装（不使用 `ubuntu-server` 元包，不装 `linux-image`，不装
  `initramfs-tools`，不装通用 `linux-firmware`）。
- 写入板级覆盖层 `rootfs/ubuntu/`，并复用参考树的 systemd 单元、udev 规则、
  NetworkManager 配置、ALSA UCM2。
- 安装固件、模块、Caihong 用户态工具（`caihong-battery` 等）。
- 用 `check-aarch64-glibc.sh` 判定预编译 SSC 载荷能否在 glibc 2.35 上运行，
  不能则跳过并记录。
- 清理：删除 qemu 解释器、`policy-rc.d`、apt 缓存、SSH 主机密钥，清空
  `machine-id`，写 `/etc/caihong-rootfs-build-info` 与 `caihong-packages.txt`。

### 4.3 `package-ubuntu-boot.sh`

`tools/bootimg_v2.py` 复现 AOSP boot image v2 布局：header 1660 字节、4096 页、
kernel 43.9 MiB、DTB 142.9 KiB、无 ramdisk、`dtb_addr=0x04000000`。
该工具已用参考 Release 的镜像做过字节级回放验证：除 32 字节 `id` 外完全一致
（参考镜像的 `id` 是陈旧的，两个不同 cmdline 的变体共享同一个 `id`）。

### 4.4 `build-ubuntu-image.sh`

`mkfs.ext4 -d` 直接从一个目录树构建 ext4（不需要 loop 设备，容器内也能跑），
label 与 `root=PARTLABEL=` 一致；`e2fsck -fn`、`img2simg`、`simg2img` 解码回读
验证后压缩、分片，并产出一份 manifest 与 SHA256SUMS。

## 5. 可重复性与审计

- 内核包、DTB、Image、固件均有固定 SHA-256。
- 镜像内 `/etc/caihong-packages.txt` 记录**实际安装的每个包的版本**；
  `/etc/caihong-rootfs-build-info` 记录内核版本、来源、构建时间、SSC 状态。
- `release/*-manifest.env` 记录镜像逻辑大小、内核摘要、构建时间。

## 6. CI

`.github/workflows/ubuntu-image.yml` 在 GitHub 的 `ubuntu-22.04` runner 上：
安装 qemu-user-static + binfmt → 从参考仓库 Release 下载并校验内核包 →
`prepare` → 构建 rootfs → 打包 boot/镜像 → `verify` → 上传产物。

> 该工作流需要能访问 GitHub Release 资产；如果内网构建，把内核包放到
> `release/` 并跳过 `Fetch the pinned Caihong kernel package` 步骤即可。

## 7. 常见构建失败

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Unable to locate package systemd` | 目标内 apt 列表为空 | 脚本已内置 `apt-get update`；若手工调试记得先跑 |
| `component 'main,universe,...' misspelt` | `sources.list` 用了逗号分隔 | 脚本已用空格分隔；`debootstrap` 才用逗号 |
| `GLIBC_2.38 not found` | 预编译载荷与 Jammy 不匹配 | 由 `check-aarch64-glibc.sh` 在构建期拦截 |
| `cp: not writing through dangling symlink resolv.conf` | 复用了已完成的树 | 脚本已先删除该符号链接 |
| `e2fsck` 报错 | 目录树里有运行中的挂载点 | 构建脚本会在打包前卸载 `/proc /sys /dev` |
