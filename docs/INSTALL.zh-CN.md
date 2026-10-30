# 安装与回退指南（Caihong Ubuntu 22.04）

> 本指南中的每一步都区分「只读检查」与「会写设备」。**本项目不会自动刷写设备**，
> `scripts/install-dualboot.sh` 默认只做 dry-run。

## 0. 风险概览

| 操作 | 影响 Android | 可恢复性 |
| --- | --- | --- |
| 刷 `boot_<slot>` | 该槽的 Android 内核被替换 | 可恢复（备份原镜像） |
| 擦 `dtbo_<slot>` | 该槽的 DTBO 被清空 | 可恢复（备份原镜像） |
| 刷 `vbmeta`（关闭 AVB） | 整机校验被关闭 | 可恢复（刷回原厂 `vbmeta.img`） |
| 刷 `linux` 分区 | **不影响** Android | 直接删除分区/重刷即可 |
| 刷 `userdata` 分区 | **删除全部 Android 用户数据** | 需原厂固件 + 全盘重刷 |
| 修改分区表 | 可能导致整机无法启动 | 需原厂 GPT/`partition.xml` 恢复 |
| `--set-active=<slot>` | 切换启动槽 | 切回另一槽即可 |

**双系统方案不修改分区表、不触碰 `userdata`**，这是默认推荐路径。

## 1. 前置条件

```sh
# 主机侧
sudo apt-get install -y android-tools-adb android-tools-fastboot zstd
adb devices          # 设备已授权
fastboot --version
```

- bootloader 已解锁（`fastboot flashing unlock`，会清空数据）
- 已下载同一 Release 的 boot 镜像与全部 rootfs 分片
- 已阅读本文件第 6 节的回退步骤
- **Android 侧重要数据已备份**（双系统也需要，因为解锁会清空）

## 2. 准备镜像

```sh
# 校验
sha256sum caihong-ubuntu22.04-jammy-boot-linux.img
cat caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst.part-* \
  > caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst
sha256sum caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst
zstd -d caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst \
  -o caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img
sha256sum caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img
```

把结果与 Release 中的 `SHA256SUMS` 逐条对比。**校验不一致的镜像不要刷。**

## 3. 检查设备与分区（只读）

```sh
adb reboot bootloader
fastboot devices
fastboot getvar product          # 必须输出 caihong
fastboot getvar current-slot     # 当前 Android 所在槽
fastboot getvar partition-size:linux
fastboot getvar all 2>/dev/null | grep -E 'partition-size:(linux|userdata|boot_|dtbo_)'
```

在设备上确认已有 `linux` 分区（GPT 分区名，不是文件系统标签）：

```sh
adb shell 'ls -l /dev/block/by-name/ | grep -E "linux|userdata"'
```

如果需要新的 `linux` 分区，**必须**在 recovery 中用 `parted` 手动操作，并保持
`userdata` 起点不变。具体命令与注意事项见参考项目
`README.zh-CN.md` 的「创建或核对 Linux 分区」一节；本移植不自动修改分区表。

## 4. 备份当前启动镜像（强烈建议）

```sh
# 方式 A：Android 已 root / 有 recovery
adb shell su -c 'dd if=/dev/block/by-name/boot_b  of=/sdcard/backup-boot_b.img'
adb shell su -c 'dd if=/dev/block/by-name/dtbo_b  of=/sdcard/backup-dtbo_b.img'
adb pull /sdcard/backup-boot_b.img
adb pull /sdcard/backup-dtbo_b.img

# 方式 B：没有 root 时，至少记录槽位与分区大小，并准备原厂 boot.img
fastboot getvar current-slot
fastboot getvar partition-size:boot_b
```

把 `backup-boot_b.img`、`backup-dtbo_b.img`、原厂 `vbmeta.img` 保存在主机上。
**没有备份就不要执行第 5 步。**

## 5. 安装（双系统，推荐）

```sh
# 5.1 先看计划：不写任何东西
scripts/install-dualboot.sh --variant linux --slot b --list
scripts/install-dualboot.sh --variant linux --slot b

# 5.2 确认无误后执行（会要求输入 "caihong linux"）
scripts/install-dualboot.sh --variant linux --slot b \
  --vbmeta /path/to/original/vbmeta.img --apply
```

脚本实际执行的命令等价于：

```sh
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fastboot erase dtbo_b
fastboot flash boot_b caihong-ubuntu22.04-jammy-boot-linux.img
fastboot flash linux  caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img
fastboot --set-active=b
fastboot reboot
```

`vbmeta` 必须来自**与该设备 Android 版本匹配的原厂固件**，否则 bootloader 可能
拒绝启动。若此前已关闭 AVB，可省略 `--vbmeta`。

## 6. 首次启动

1. 设备重启后先出现 bootloader 画面，随后内屏应显示内核日志（`loglevel=7`）。
2. 首次启动会执行 `caihong-grow-rootfs.service` 把 ext4 扩展到整个 `linux` 分区，
   因此比后续启动慢。
3. 出现 `caihong login:` 后使用 `root/caihong` 登录。
4. **立即修改密码**：

```sh
passwd
passwd caihong
```

5. 需要 SSH 时先用 USB-C 网卡或串口以外的可用链路拿到地址：

```sh
ip -br addr
systemctl status ssh
```

## 7. 单系统安装（会删除 Android 数据）

```sh
scripts/install-dualboot.sh --variant userdata --slot b --list
scripts/install-dualboot.sh --variant userdata --slot b \
  --vbmeta vbmeta.img --apply
```

该变体把镜像写入 `userdata` 分区。**执行后 Android 用户数据不可恢复**，除非用原厂
固件全盘重刷。

## 8. 回退到 Android

```sh
adb reboot bootloader

# 切回 Android 所在槽（假设 Android 在 a 槽）
fastboot --set-active=a
fastboot reboot
```

如果你替换过 `boot_b` / `dtbo_b`：

```sh
fastboot flash boot_b backup-boot_b.img
fastboot flash dtbo_b backup-dtbo_b.img
fastboot --set-active=a
fastboot reboot
```

只擦除了 `linux` 分区内的数据时，Android 完全不受影响。

**最坏情况**（分区表被改坏）：使用原厂 `partition.xml`/`rawprogram*.xml` 在
Qualcomm 9008 模式下全盘恢复。此操作会清空设备，且需要原厂固件。

## 9. 已知首次启动问题与排查

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 内屏黑屏但设备在跑 | msm 模块未加载 / fbcon 未接管 | `adb shell dmesg \| grep -i msm`（adbd 可能需要 USB-C 重新插拔） |
| 卡在 bootloader | vbmeta 未关闭 AVB | 用原厂 vbmeta 加 `--disable-verity --disable-verification` |
| `root=` 找不到 | 分区名不是 `linux` | `fastboot getvar all` 核对，或用 `--variant userdata` |
| 电池读数为空 | `qcom_battmgr` 未绑定 | `dmesg \| grep battmgr`，`ls /sys/class/power_supply` |
| USB 不识别 | Type-C 角色未切换 | `cat /sys/class/typec/port0/data_role`，重插线缆 |

把 `sudo scripts/collect-debug.sh` 生成的归档连同现象一起提交，才能定位问题。
