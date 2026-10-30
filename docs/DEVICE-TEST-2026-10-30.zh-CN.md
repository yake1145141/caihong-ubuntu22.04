# 真机验证记录（2026-10-30）

设备：一加平板 Pro（`OPD2404` / 内部 `OP5D77L1`），S/N `67ab95c8`
刷入方式：单系统，`userdata` 分区（Android 数据已按确认清除），槽位 B
系统：Ubuntu 22.04 LTS，内核 `7.3.0-g77f2f22ff4f9`

本文件只记录**在设备上实际执行过**的命令与输出。所有结论都可用下面给出的命令复现。

---

## 1. 已通过（真机实测）

### 1.1 启动与登录（P0）

```
$ uname -a
Linux caihong 7.3.0-g77f2f22ff4f9 #1 SMP PREEMPT Sun Oct 25 12:37:51 UTC 2026 aarch64
$ . /etc/os-release; echo $PRETTY_NAME
Ubuntu 22.04 LTS
```

内屏出现 `caihong login:`；`getty@tty1` 与 `ssh.service` 均正常。

### 1.2 内屏与原生分辨率（P0）

```
$ ls -l /dev/dri
crw-rw---- 1 root video  226,   0 card0
crw-rw---- 1 root render 226, 128 renderD128
$ cat /sys/class/drm/card0/card0-DSI-1/status
connected
$ head -3 /sys/class/drm/card0/card0-DSI-1/modes
3000x2120
3000x2120
3000x2120
$ cat /sys/class/drm/card0/card0-DP-1/status
disconnected
```

DRM 驱动 `msm_dpu`（`OF_COMPATIBLE_0=qcom,sm8650-dpu`），GPU devfreq 在线：

```
$ cat /sys/class/devfreq/3d00000.gpu/cur_freq
231000000
```

### 1.3 亮度（P1）

```
$ bl=/sys/class/backlight/ktz8866-backlight
$ cat $bl/max_brightness $bl/actual_brightness
2047 1500
$ echo 400 > $bl/brightness; cat $bl/actual_brightness
400
$ echo 1800 > $bl/brightness; cat $bl/actual_brightness
1800
$ echo 1500 > $bl/brightness; cat $bl/actual_brightness
1500
```

### 1.4 电池（P0）

```
$ caihong-battery
qcom-battmgr-bat (Battery)
  status      : Charging
  capacity    : 50%
  voltage     : 3.825V
  current     : -1.370A
  temperature : 32.000 C
  health      : Good
  model       : Caihong_TABLET_9510MAH_AVERAGED_MASTERSLAVE_DEC18TH2023
  cycles      : 0
```

> 这一项在最初的移植中判断错误：`caihong-battery` 原先按 `scope=Device` 过滤，而
> `qcom-battmgr-*` 节点没有该属性，导致误报“没有电源节点”。已修复（改为只跳过显式
> `scope=System` 的 UCSI 重复节点）。

### 1.5 USB-C 充电检测（P0，供电链路）

```
qcom-battmgr-usb:  type=USB  online=1       voltage=4.503V  current=0.450A
qcom-battmgr-wls:  type=Wireless online=0
sc8547-0-6f:       type=Mains online=0      voltage=4.508V  temp=300
sc8547-1-6f:       type=Mains online=0      voltage=4.526V  temp=305
ucsi-source-psy:   type=USB  online=1  status=Charging  voltage=5.000V  current=0.100A
```

插入 USB-C 电源后 `qcom-battmgr-usb.online=1`、电池 `status=Charging`，拔掉后恢复
放电状态，验证了 power_supply 链路与 UCSI 检测。

### 1.6 首次启动扩容

```
$ df -h /
/dev/root       216G  747M  216G   1% /
$ findmnt -n -o SOURCE,FSTYPE,OPTIONS /
/dev/sda14 ext4 rw,noatime,errors=remount-ro
$ ls -l /var/lib/caihong-rootfs-grown
-rw-r--r-- 1 root root 0 /var/lib/caihong-rootfs-grown
```

镜像逻辑大小 2304 MiB → 首次启动扩展到 219 GB 分区成功。

### 1.7 温控与 CPU 调频（P1）

```
thermal zones: aoss0 36.0C, cpuss0 38.7C, cpu4-bottom 38.0C, cpu5-top 38.0C,
               cpu6-top 37.6C, cpu7-top 38.5C, cpu0 38.9C ...
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
ondemand
$ cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
2265600
```

与参考项目一致：默认不启用 3.3024 GHz boost。

### 1.8 Wi-Fi（P1）

```
$ ip -br addr show wlp1s0
wlp1s0  UP  192.168.2.122/24
$ iw dev wlp1s0 scan | grep -E 'SSID|freq'
freq: 2422  SSID: YaKe
freq: 2462  SSID: CMCC-304
$ curl -o /dev/null -w '%{http_code}\n' http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/
200
```

ath12k 驱动 + WCN7850 固件工作，DHCP 与联网正常，SSH 可远程登录（本报告所有命令均
通过 SSH 执行）。

### 1.9 USB-C 设备模式与 USB 网卡调试通道（非验收项，工程手段）

```
$ ls /sys/class/udc
a600000.usb
$ cat /sys/class/usb_role/a600000.usb-role-switch/role
device
```

主机侧枚举为 `VID_1D6B:PID_0104`，`usb0=192.168.55.1/24`。这是无键盘/无串口时唯一
可用的登录通道，镜像内置 `caihong-usbnet.service`（CDC-NCM）。

> 主机侧两个坑（已记录在 `docs/BUILD.zh-CN.md`）：Windows 11 24H2 之后不再自带 RNDIS
> 驱动（故用 NCM）；cdc_ncm 需在 Windows 端关闭网卡的 TCP/UDP 校验和分载，否则
> ICMP 通但 TCP 全部超时。

---

## 2. 未通过 / 未完成

### 2.1 GPU 硬件加速（P0，**已通过，需随镜像安装 Mesa 24.3.4**）

> Jammy 自带的 Mesa 23.2.1 在 Adreno 750 上崩溃（见下方原始记录）。改用在本机
> 原生构建的 **Mesa 24.3.4** 后 GPU 完全可用。该 Mesa 已作为
> `vendor/mesa/caihong-mesa-24.3.4-aarch64.tar.zst` 打进镜像
> （`scripts/install-caihong-mesa.sh`）。

```
$ kmscube -c 300
Using display 0xaaab12018130 with EGL version 1.5
  version: "OpenGL ES 3.2 Mesa 24.3.4"
  vendor: "freedreno"
  renderer: "FD750"
exit=0

$ vulkaninfo --summary | grep -E 'deviceName|driverName'
  deviceName = Turnip Adreno (TM) 750
  driverName = turnip Mesa driver

$ cat /sys/class/devfreq/3d00000.gpu/cur_freq   # 渲染期间
500000000        # 231 MHz 空闲 → 500 MHz 负载，max 834 MHz
```

同步观测：GPU 温度 `gpuss0..4 = 40.0~41.2 °C`，渲染后 dmesg 无 GPU fault。

### 2.1.1 原始问题记录（Mesa 23.2.1）

内核侧完全正常，用户空间崩溃：

```
$ strace -e ioctl kmscube -c 1
ioctl(5, DRM_IOCTL_MSM_SUBMITQUEUE_NEW, 0xfffffccaa800) = 0
--- SIGSEGV {si_signo=SIGSEGV, si_code=SEGV_MAPERR, si_addr=NULL} ---
```

- `kmscube`、`eglinfo`、`vulkaninfo` 均 SIGSEGV（exit 139）
- 设置 `LIBGL_ALWAYS_SOFTWARE=1` 后**同样崩溃**，说明崩溃发生在 Mesa 的
  kgsl/freedreno DRM 后端初始化，而不是着色器/渲染路径
- `vulkaninfo` 附加信息：`terminator_CreateInstance: Failed to CreateInstance in ICD 1`

根因判断：Jammy 提供 Mesa **23.2.1**，该版本虽在设备表中列出 `FD730`，但其 kgsl 后端
与本内核（7.3.0）的 `MSM_SUBMITQUEUE` 接口存在不兼容，初始化即崩。参考项目使用 Arch
的 Mesa 24/25。下一步见 §3。

### 2.2 蓝牙（P1，**未通过**）

```
$ hciconfig -a
hci0: Type: Primary  Bus: UART
      BD Address: 00:00:00:00:5A:AD  ACL MTU: 0:0  SCO MTU: 0:0
      DOWN RAW
$ btmgmt -i 0 power on
Set Powered for hci0 failed with status 0x11 (Invalid Index)
$ bluetoothctl list
(空)
```

`caihong-hardware-mac.service` 失败于 “Bluetooth controller did not become ready”，
`caihong-bluetooth-autostart.service` 因重启过快被 systemd 限制。控制器停留在
`DOWN RAW` 且地址全零，说明 QCA 固件下载（`qcom/hmtbtfw20.tlv`）未成功。dmesg 中可见
btqca 的 HCI 厂商寄存器转储，属于下载失败后的诊断输出。

### 2.3 USB Host / Hub / OTG（P0，**未测**）

单口设备在插着主机时处于 **device** 角色（`usb_role=device`），此时没有 xHCI 主机
控制器实例，`lsusb` 为空。要验证 Hub/键盘/U 盘必须：

1. 拔掉与 PC 的连接，改用 USB-C Hub（或 OTG 转接）接外设；
2. 或从主机侧强制 `echo host > /sys/class/usb_role/*/role`（需确认 Type-C PD 供电）。

本次没有相应硬件，故未测。

### 2.4 DisplayPort Alt Mode（P1，**未测**）

`card0-DP-1/status = disconnected`，无 DP 扩展坞可测。

### 2.5 触摸屏 / 手写笔 / Pogo 键盘（P1，**未测**）

`nt36532e_ts.ko`、`oneplus_pogo.ko`、`caihong-pen-power` 均在镜像中（模块存在），
但没有键盘/触控输入设备可做端到端验证。

### 2.6 休眠/唤醒（P1，**未测**）

### 2.7 传感器（SSC，P2，**已知不可用**）

预编译 bundle 需 GLIBC_2.38，Jammy 为 2.35，构建期已跳过并记录
`ssc=incompatible-glibc`。

### 2.8 摄像头（P2，**未移植**）

参考项目自建 libcamera/Camera ICP 栈未包含。

---

## 3. 下一步（按优先级）

1. **GPU**：在设备上原生构建 Mesa 24.3.4（freedreno + turnip，无 X11/Wayland），
   以 `LD_LIBRARY_PATH` 方式验证 `kmscube`；验证通过后作为独立图形包并入镜像。
   构建命令见 `docs/BUILD.zh-CN.md` 的 “GPU 用户空间” 一节。
2. **蓝牙**：抓 `dmesg` 全量（当前 ring buffer 被调试输出冲掉），确认
   `hmtbtfw20.tlv` 下载失败点；核对 `hci_uart` 的 qca 协议初始化时序，并在
   `caihong-hw-report` 类服务里保留失败日志。
3. **USB Host**：接入 USB-C Hub，验证 `dwc3` 角色切换到 host、Hub 级联与外设枚举。
4. **DP Alt Mode**：接 DP 扩展坞，确认 `card0-DP-1` 转 connected 并输出模式。
5. **触摸/键盘/休眠**：接入对应外设后逐项验证。
