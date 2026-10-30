# Caihong 硬件支持清单（Ubuntu 22.04 移植版）

本文档只记录**有证据**的结论。证据分四级，逐条标注：

| 级别 | 含义 |
| --- | --- |
| `[S]` 源码/配置分析 | 来自内核内嵌配置、设备树、驱动源码或仓库脚本的确定事实 |
| `[B]` 构建通过 | 本次构建实际产出了对应文件/模块/服务 |
| `[V]` 结构校验 | `verify-ubuntu-image.sh` 对镜像结构、文件、哈希的校验通过 |
| `[D]` 真机验证 | 需要在设备上执行，**本次未进行** |

内核事实来自从 `Image` 中还原的 `/proc/config.gz`（见
`kernel/caihong-kconfig-7.3.0.txt`，10284 行），不是猜测。设备树事实来自
`build/kernel/caihong.dtb`（`compatible = "oneplus,caihong", "qcom,sm8650"`，
`model = "Oneplus Pad Pro"`）。

## 1. 启动链

| 项目 | 内容 | 证据 |
| --- | --- | --- |
| 启动镜像格式 | Android boot image v2，header_size=1660，page_size=4096 | `[S]` 解析参考镜像 + `[V]` 自研打包器复现 |
| 载荷 | `Image`(45,988,352 B) + DTB(146,295 B)，**ramdisk_size=0** | `[S]``[V]` |
| 根文件系统 | `root=PARTLABEL=linux`（双系统）/ `userdata`（单系统），ext4 | `[S]``[B]` |
| 是否需要 initramfs | **不需要**：`CONFIG_EXT4_FS=y`、`CONFIG_SCSI_UFSHCD=y`、`CONFIG_SCSI_UFS_QCOM=y` | `[S]` |
| A/B 槽 | 只写当前运行槽的 `boot_<slot>`，擦 `dtbo_<slot>` | `[B]` `install-dualboot.sh` |

## 2. 显示与背光（P0）

| 项目 | 驱动/节点 | 用户空间 | 状态 |
| --- | --- | --- | --- |
| 内屏面板 | `CONFIG_DRM_PANEL_NOVATEK_NT36532=y`（内置），DSI 链路由 DTB 描述 | — | `[S]` 内核已内置面板驱动 |
| 显示控制器 | `msm.ko`（`CONFIG_DRM_MSM=m`，含 DPU/DSI/DP） | — | `[B]` 模块在镜像 `/lib/modules/7.3.0-g77f2f22ff4f9/kernel/drivers/gpu/drm/msm/msm.ko` |
| 文本控制台 | `CONFIG_DRM_FBDEV_EMULATION=y` + `CONFIG_FRAMEBUFFER_CONSOLE=y` + `CONFIG_VT_CONSOLE=y` | getty@tty1、Terminus 16x32 控制台字体 | `[S]``[B]` 控制台链路完整；`[D]` 需确认实际点亮 |
| 背光 | `CONFIG_BACKLIGHT_CLASS_DEVICE=y`，`ktz8866`（`CONFIG_BACKLIGHT_KTZ8866=y`） | `/sys/class/backlight/*/brightness` | `[S]`；`[D]` 需实测 |
| 分辨率/刷新率 | DTB 中的 panel 时序 | — | `[D]` 3000×2120、60/120 Hz 需实测；144 Hz 与参考项目一致仍需模式切换 |
| 外接显示（DP Alt Mode） | `CONFIG_TYPEC_DP_ALTMODE=y`、`CONFIG_DRM_MSM_DP=y` | `drm` 连接器 | `[S]`；`[D]` 需 DP 扩展坞实测 |

## 3. GPU（Adreno 750 / a730，P0）

| 项目 | 内容 | 状态 |
| --- | --- | --- |
| 内核驱动 | `msm.ko`，`CONFIG_DRM_MSM_GPU_STATE=y`，`CONFIG_PM_DEVFREQ=y` | `[B]` |
| 固件 | `qcom/gmu_gen70900.bin`、`qcom/gen70900_sqe.fw` | `[B]` 已装入 `/usr/lib/firmware` |
| DRM 节点 | `/dev/dri/card0`、`/dev/dri/renderD128` | `[D]` |
| GL/EGL 用户空间 | **Mesa 24.3.4**（自建 bundle，freedreno）覆盖 Jammy 的 23.2.1 | `[D]` 真机 `kmscube` 300 帧，`renderer: FD750`，GPU 升频至 500 MHz |
| Vulkan | Mesa 24.3.4 的 Turnip | `[D]` `vulkaninfo` 报告 `Turnip Adreno (TM) 750` / `turnip Mesa driver` / Vulkan 1.3.296 |
| 硬件加速判定 | `kmscube` 能出画面 + `glmark2-es2` 的 GL_RENDERER 显示 `FD730`/`freedreno` | `[D]` |

> 结论：GPU 的**内核侧**证据完整（模块 + 固件 + DRM 配置），**用户空间 GL** 由
> Jammy 官方 Mesa 23.2.1 提供。是否真正走硬件路径必须用 `kmscube`/`glmark2-es2`
> 在设备上确认，`llvmpipe` 回退会显示为软件渲染。

## 4. 电池与充电（P0）

| 项目 | 驱动 | 节点 | 状态 |
| --- | --- | --- | --- |
| 电池电量/状态 | `CONFIG_BATTERY_QCOM_BATTMGR=y`、`CONFIG_BATTERY_QCOM_BATTMGR_CAIHONG=y`（均为内置） | `/sys/class/power_supply/*`（`capacity`/`status`/`voltage_now`/`current_now`/`temp`） | `[S]``[B]` `caihong-battery` 直接读取，不伪造数据 |
| 充电泵 | `sc8547_cp.ko`（`CONFIG_CHARGER_SC8547_CAIHONG=m`） | `power_supply` 从属节点 | `[B]` |
| USB-C 供电检测 | `CONFIG_TYPEC=y`、`CONFIG_TYPEC_UCSI=y`、`CONFIG_UCSI_PMIC_GLINK=y`、`CONFIG_QCOM_PMIC_GLINK=y` | `/sys/class/typec/` | `[S]` |
| 手写笔充电 | `caihong_pen_power.ko` | — | `[B]` |
| 私有快充协议 | 参考项目称 PPS/VOOC 可用；功率与温度限流由内核/固件决定 | — | `[D]` 不宣称最高功率 |

## 5. USB-C / OTG / Hub（P0）

| 项目 | 配置 | 状态 |
| --- | --- | --- |
| USB 控制器 | `CONFIG_USB_DWC3=y`（`_QCOM=y`、`DUAL_ROLE=y`）、`CONFIG_USB_XHCI_HCD=y`、`USB_XHCI_PLATFORM=y` | `[S]` 内置 |
| Type-C 角色切换 | `CONFIG_TYPEC=y`、`CONFIG_TYPEC_QCOM_PMIC=m`、`CONFIG_UCSI_PMIC_GLINK=y` | `[S]` |
| Gadget / adbd | `CONFIG_USB_GADGET=y`，FunctionFS 可用；**Jammy 无 `adbd` 包**，Debian 版本需 GLIBC_2.36+ | `[S]` 服务因缺少 `/usr/bin/adbd` 不启用；USB host/OTG 不受影响 |
| Hub / 下游设备 | XHCI 内置，Hub 无需额外驱动 | `[S]`；`[D]` 键盘/鼠标/U 盘/网卡/多级 Hub 需实测 |

## 6. 无线

| 项目 | 驱动/固件 | 状态 |
| --- | --- | --- |
| Wi-Fi | `ath12k.ko` + `ath12k_wifi7.ko`；`firmware/ath12k/WCN7850/hw2.0/{board-2.bin,caihong/*.bin}` | `[B]`；NetworkManager + wpa_supplicant；`[D]` |
| 硬件 MAC | `caihong-hardware-mac.service` + `caihong-nvram-mac`（从 NVRAM 读取） | `[B]`（若构建机有 gcc/OpenSSL 头）；`[D]` |
| 蓝牙 | `bluetooth.ko`、`hci_uart.ko`（QCA）、`firmware/qca/hmtbtfw20.tlv`、`hmtnv20.bin` | `[B]` bluez 已装；`[D]` |
| 热点/STA 并发 | `caihong-hotspot`（nmcli + iw + nft） | `[B]` 脚本随镜像；`[D]` |

## 7. 输入

| 项目 | 驱动/固件 | 状态 |
| --- | --- | --- |
| 触摸屏 | `nt36532e_ts.ko`（`CONFIG_TOUCHSCREEN_NT36532E=m`）+ `firmware/novatek/DT-novatek-nt36532.bin` + `hid_multitouch.ko` | `[B]`；`[D]` |
| 手写笔 | `caihong-pen-{pair,charge,autoconnect}` + `caihong_pen_power.ko` | `[B]`；`[D]` |
| Pogo 键盘 | `oneplus_pogo.ko` + `99-caihong-pogo-input.rules` | `[B]`；`[D]` |

## 8. 其他

| 功能 | 状态 |
| --- | --- |
| UFS 存储 | `[S]` 内置驱动；`[B]` 以 UFS 上的 ext4 为根 |
| CPU 调频 | `[S]` `CONFIG_ARM_QCOM_CPUFREQ_HW=y` + `cpufrequtils`；`[D]` |
| 温控 | `[S]` `CONFIG_QCOM_TSENS=y`、`THERMAL_GOV_STEP_WISE=y`；`[B]` `lm-sensors` |
| 休眠/恢复 | `[S]` 内核支持 s2idle/deep；`[D]` 未验证 |
| 音频 | `[B]` `q6apm`/`wcd939x`/`aw88261` 模块 + Caihong UCM2 + AudioReach topology；`[D]` |
| 传感器（SSC） | `[S]` **不可用**：预编译 `iio-sensor-proxy`/`libhexagonrpc` 需要 GLIBC_2.38，Jammy 为 2.35，构建时自动跳过 |
| 摄像头 | 参考项目的自建 libcamera/Camera ICP 栈未移植（`[S]` 明确记录为未实现） |
| NPU/VPU | `[S]` 内核模块在；NPU 运行时载荷体积大且依赖 libdir 布局，默认未安装，记录为可选步骤 |

## 9. 与 Arch 参考实现的关键差异

| 项目 | Arch 参考 | Ubuntu 移植 | 原因 |
| --- | --- | --- | --- |
| 包管理 | pacman | apt/dpkg（ubuntu-ports） | 发行版要求 |
| 内核安装位置 | `/usr/lib/linux-caihong/modules/<rel>` + pacman 钩子 | `/lib/modules/<rel>`（usrmerge 后即 `/usr/lib/modules`）+ `depmod` | Ubuntu 模块加载路径 |
| adbd | Debian 静态载荷 + `LD_LIBRARY_PATH` 私有库 | Ubuntu 官方 `android-tools-adbd` | 避免跨发行版 glibc 依赖 |
| 敏感用户组 | `wheel` | `sudo` | Ubuntu 约定 |
| initramfs | 无 | 无（保持一致） | 启动链不含 ramdisk |
| 桌面 | KDE Plasma | 不安装（Server），`caihong-fix-kwin-brightness`/`caihong-clean-pogo-kde` 不安装 | 目标为 Server |
| 传感器 | SSC bundle | 跳过（glibc 2.38） | Jammy 无法加载 |
| 扩容服务 | `resize2fs /dev/disk/by-label/linux` | 从 `findmnt /` 解析设备 | 同一镜像兼容两种分区标签 |

## 10. 真机验证清单（尚未执行）

按 `[D]` 逐项执行，并把 `scripts/collect-debug.sh` 的输出附在报告里：

```sh
# 0) 启动与内屏
cat /proc/cmdline; dmesg | grep -iE 'msm|drm|panel|fbcon'
ls /sys/class/drm/; cat /sys/class/drm/card*-*/status

# 1) 亮度
ls /sys/class/backlight/; for b in /sys/class/backlight/*; do
  echo 40 > $b/brightness; done

# 2) 电池与充电
caihong-battery            # 拔掉充电器
caihong-battery            # 插入 USB-C 电源后再跑一次

# 3) USB-C / Hub
lsusb; lsusb -t; cat /sys/class/typec/port0/data_role

# 4) GPU
kmscube -c 120
glmark2-es2 --off-screen 2>/dev/null | head -20

# 5) 网络
nmcli device; ip -br addr; bluetoothctl show

# 6) 外接显示
cat /sys/class/drm/card0-DP-*/status

# 7) 诊断归档
sudo scripts/collect-debug.sh --out /var/tmp
```
