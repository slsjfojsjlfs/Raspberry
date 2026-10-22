# Raspberry Pi 5 开发项目

本项目用于 Raspberry Pi 5 开发板的软件、设备树和 GPIO 外设开发。

## 光谱重建算法

`algorithms/spectral-reconstruction` 已实现适用于 Raspberry Pi 5 的 v14-r8 CPU/NumPy
光谱重建框架，并部署到开发板 `/home/r/Raspberry/Algorithm`；算法输出统一写入
`/home/r/Raspberry/Result`。实现包含 41 通道 manifest 校验、暗场/白场或显式
缩放预处理、磁盘映射、分块二次回归、101 维光谱输出、可选 RGB 渲染以及哈希和
耗时报告。

Raspberry Pi 5 没有 Rockchip NPU，因此不运行 `.rknn` 模型。v14-r8 生产 NPZ 权重、
原 C++ 二进制权重、参考 `colorchecker_x41.npy` 和原实现源码已部署。板端已完成生产
权重执行验证以及 NPZ/BIN 参数逐元素一致性检查，结果保存在
`/home/r/Raspberry/Result/reference_validation`。当前仍缺少 IMX568 与训练模型一致的
41 档真实偏压表、暗场/白场标定和真值光谱，因此实拍光谱精度尚未验收。详细算法、
目录、权重哈希、运行方式和验收条件见 `algorithms/spectral-reconstruction/README.md`。

## 开发板基线

以下信息于 2026-10-13 通过开发板实机读取：

| 项目 | 当前值 |
| --- | --- |
| 型号 | Raspberry Pi 5 Model B Rev 1.1 |
| 架构 | AArch64 |
| 内核 | Linux 6.18.50+rpt-rpi-2712 |
| SSH 地址 | `r@192.168.137.2` |
| 40 针排针 GPIO 控制器 | RP1 `gpiochip0`（兼容入口 `/dev/gpiochip4`） |
| 普通用户权限 | 用户 `r` 已加入 `gpio`、`i2c`、`spi` 等用户组 |

连接命令：

```powershell
ssh r@192.168.137.2
```

> 登录密码等凭据不要提交到项目文件或版本控制中。

## VC MIPI IMX568 摄像头驱动

2026-10-19 已按 [VC MIPI 官方仓库](https://github.com/VC-MIPI-modules/vc_mipi_raspi)
说明，在 Raspberry Pi 5（BCM2712、arm64）上安装并重启验证：

| 组件 | 版本/状态 |
| --- | --- |
| VC MIPI 驱动 | `vc-mipi-driver-bcm2712 0.7.0`，已安装 |
| DKMS | `3.2.2-1~deb13u1`，已安装 |
| v4l-utils | `1.30.1-1`，已安装 |
| 当前内核模块 | `vc_mipi_camera`、`vc_mipi_core`、`vc_mipi_modules` 已加载 |
| IMX568 配置 | Sony、4-lane |
| CAM0/CAM1 | 两路均已启用，便于接入任一 Pi 5 相机口 |

离线安装包保存在 `packages/vc-mipi/`。官方发布包的 SHA-256 为：

```text
vc-mipi-driver-bcm2712_0.7.0_arm64.deb
160359c731ff057054e099c146eb4d5b1399eb1509cd6a954a3b2eb07ebda9f4

dkms_3.2.2-1-deb13u1_all.deb
6840d049df96419be706d135bcba4355e08864b0794977a616db16330871d412
```

安装器创建或修改的启动文件：

- `/boot/firmware/config_vc-mipi-driver-bcm2712.txt`：CAM0/CAM1 overlay、Sony、4-lane；
- `/boot/firmware/config.txt`：包含上述摄像头配置文件；
- `/boot/firmware/config.txt.bak`：安装前配置备份。

当前配置关键内容：

```ini
# CAM0
dtoverlay=vc-mipi-bcm2712-cam0
dtparam=cam0_lanes4
dtparam=cam0_manu_sony
dtparam=cam0_libcamera_off

# CAM1
dtoverlay=vc-mipi-bcm2712-cam1
dtparam=cam1_lanes4
dtparam=cam1_manu_sony
dtparam=cam1_libcamera_off

dtoverlay=vc-mipi-common-memory-contiguous
```

### 当前硬件探测状态

软件安装和设备树加载成功，但截至 2026-10-19，相机模块尚未被硬件探测到：

- CAM0 对应 I²C bus 10，无设备响应；
- CAM1 对应 I²C bus 11，无设备响应；
- 内核在两路均报告模块控制地址 `0x10` 无响应；
- `rp1-cfe` 两路 CSI 控制器存在，但尚未生成相机 capture video node。

这通常表示排线、接头、转接板或模块供电链路未连通。此驱动面向 Vision
Components VC MIPI 模块；如果设备只是采用 IMX568 芯片的其他厂商相机或裸传感器，
其 I²C 地址、初始化和设备树可能不同，不能仅凭传感器型号直接使用本驱动。

重新检查硬件时：

1. 先执行 `sudo poweroff`，彻底断电后再插拔排线；
2. 检查 Pi 5 的 22-pin CAM/DISP 接口、VC 转接板和排线触点方向；
3. 确认模块及转接板获得正确供电；
4. 上电重启后运行以下检查命令。

```bash
# 软件和内核模块
dpkg-query -W dkms vc-mipi-driver-bcm2712 v4l-utils
dkms status
lsmod | grep vc_mipi

# CAM0 和 CAM1 的 I2C 探测
sudo i2cdetect -y 10
sudo i2cdetect -y 11

# 驱动日志和视频设备
sudo dmesg --color=never | grep -iE 'vc.mipi|imx568|rp1-cfe|csi2|camera'
v4l2-ctl --list-devices
```

相机连通后，日志应不再出现
`Unable to get module I2C client for address 0x10`，并应出现对应的 capture
`/dev/video*` 和 `/dev/v4l-subdev*` 节点。

## 上传 Image 目录

`scripts/transfer/upload-images.ps1` 用于将本地 `data/Image` 目录整体上传到
树莓派的 `/home/r/Raspberry/Image`。脚本会自动创建远端父目录、保留隐藏文件
和多级子目录，并覆盖远端同名文件；它不会删除远端已有的额外文件。
首次连接记录的服务器公钥指纹保存在项目的 `.ssh/known_hosts` 中，脚本不会
在该目录中保存密码或私钥。

在项目根目录运行（推荐，不受 PowerShell 脚本执行策略影响）：

```powershell
.\scripts\transfer\upload-images.cmd
```

也可以仅为这一次命令放行并直接运行 PowerShell 脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\transfer\upload-images.ps1
```

脚本默认连接 `r@192.168.137.2`，SSH 会在控制台中安全地询问密码，密码不会
被保存到脚本。首次使用需要为创建远端目录和上传分别输入密码。也可以覆盖参数：

```powershell
.\scripts\transfer\upload-images.cmd -RemoteHost 192.168.137.2 -RemoteUser r
```

频繁上传时建议配置 SSH 公钥认证，以免重复输入密码。

## IMX568 详细日志采集

`capture_imx568_41_detailed.sh` 在同一个 V4L2 数据流中丢弃 1 张预热帧，再连续采集 41 张 RAW8 图像，转换为 PNG，并使用内核 V4L2 buffer 时间戳生成详细日志。每次运行会清理上一次的 `image_temp_result` 内容。

板端运行：

```bash
/home/r/Raspberry/Drvier/capture_imx568_41_detailed.sh
```

结果位于 `/home/r/Raspberry/Image/image_temp_result`。除 41 张 PNG 外，还会生成：

- `capture_detailed.log`：便于人工查看的完整日志；
- `capture_report.json`：便于程序读取的结构化报告；
- `frames.csv`：逐帧时间戳、间隔、RAW/PNG 大小及 SHA-256；
- `capture_info.txt`：兼容原采集流程的摘要。

详细日志同时记录采集命令总耗时、第一帧到最后一帧的时间、脚本总耗时以及帧间隔的平均值、最小值和最大值。
绝对时间戳依赖开发板系统时间，报告会记录 `system_clock_ntp_synchronized`；帧间隔使用内核单调时钟，不受 NTP 校时影响。

只保存原始 RAW8 数据时使用：

```bash
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh
```

该脚本生成 `imx568_001.raw` 至 `imx568_041.raw`，每个文件应为 5,085,696 字节，不包含文件头；日志文件名及字段与详细 PNG 脚本保持一致。

拍摄张数和目标时间间隔可通过参数修改：

```bash
# 默认：41 张，相机自动/最大帧率
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh

# 拍摄 100 张，目标帧间隔 50 ms
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh \
  --count 100 \
  --interval-ms 50
```

`--interval-ms` 通过相机 `frame_rate` 控制项设置目标间隔，最终应以日志中的 `configured_interval_ms` 和 `frame_interval_ms` 实测值为准；运行结束后脚本会把 `frame_rate` 恢复为自动模式。

## 下载树莓派 Image 目录

`scripts/transfer/download-images.ps1` 用于将树莓派
`/home/r/Raspberry/Image` 中的全部内容递归下载到本地
`data/Image/raspberry_image`，包括隐藏文件和多级子目录。下载会覆盖本地同名文件，
但不会删除只存在于本地的额外文件。

在项目根目录运行不受 PowerShell 执行策略影响的启动器：

```powershell
.\scripts\transfer\download-images.cmd
```

默认连接 `r@192.168.137.2`，执行时输入 SSH 密码。也可以覆盖连接、远端路径
或本地路径参数：

```powershell
.\scripts\transfer\download-images.cmd `
  -RemoteHost 192.168.137.2 `
  -RemoteUser r `
  -RemoteImageDirectory /home/r/Raspberry/Image `
  -LocalDestinationDirectory G:\Rasberry\project\Raspberry\data\Image\raspberry_image
```

## 当前设备树配置

`/boot/firmware/config.txt` 当前启用的相关配置为：

```ini
dtparam=audio=on
dtoverlay=vc4-kms-v3d
dtoverlay=dwc2,dr_mode=host
dtoverlay=nospi10
```

目前没有启用 `i2c_arm`、SPI0 或主 UART。实机执行 `gpioinfo` 和
`pinctrl get 0-27` 后确认：

- GPIO2 至 GPIO27 没有被内核 GPIO consumer 占用；
- GPIO2 至 GPIO27 的引脚复用功能均为 `none`，可以用作普通数字 GPIO；
- GPIO0、GPIO1 是 HAT EEPROM 识别引脚，虽然当前为输入，但不纳入普通 GPIO 分配；
- GPIO28 至 GPIO53 以及其他 `gpiochip` 线路连接板载硬件，不作为 40 针排针资源使用。

## 40 针排针 GPIO 映射

下表使用 BCM GPIO 编号。`可用`表示在上述检查时间点没有被设备树或驱动占用。

| 物理针脚 | BCM GPIO | 默认上/下拉 | 常见复用功能 | 当前状态 |
| ---: | ---: | --- | --- | --- |
| 3 | GPIO2 | 上拉 | I²C1 SDA | 可用 |
| 5 | GPIO3 | 上拉 | I²C1 SCL | 可用 |
| 7 | GPIO4 | 上拉 | GPCLK0、UART2 TX | 可用 |
| 29 | GPIO5 | 上拉 | GPCLK1、UART2 RX | 可用 |
| 31 | GPIO6 | 上拉 | GPCLK2、I²C3 SDA | 可用 |
| 26 | GPIO7 | 上拉 | SPI0 CE1、I²C3 SCL | 可用 |
| 24 | GPIO8 | 上拉 | SPI0 CE0 | 可用 |
| 21 | GPIO9 | 下拉 | SPI0 MISO | 可用 |
| 19 | GPIO10 | 下拉 | SPI0 MOSI | 可用 |
| 23 | GPIO11 | 下拉 | SPI0 SCLK | 可用 |
| 32 | GPIO12 | 下拉 | PWM0 CH0、UART4 TX | 可用 |
| 33 | GPIO13 | 下拉 | PWM0 CH1、UART4 RX | 可用 |
| 8 | GPIO14 | 下拉 | UART0 TX、PWM0 CH2 | 可用 |
| 10 | GPIO15 | 下拉 | UART0 RX、PWM0 CH3 | 可用 |
| 36 | GPIO16 | 下拉 | UART0 CTS、SPI1 CE2 | 可用 |
| 11 | GPIO17 | 下拉 | UART0 RTS、SPI1 CE1 | 可用 |
| 12 | GPIO18 | 下拉 | I²S0 SCLK、SPI1 CE0、PWM0 CH2 | 可用 |
| 35 | GPIO19 | 下拉 | I²S0 WS、SPI1 MISO、PWM0 CH3 | 可用 |
| 38 | GPIO20 | 下拉 | I²S0 SDI、SPI1 MOSI | 可用 |
| 40 | GPIO21 | 下拉 | I²S0 SDO、SPI1 SCLK | 可用 |
| 15 | GPIO22 | 下拉 | I²C3 SDA、I²S0 SDI1 | 可用 |
| 16 | GPIO23 | 下拉 | I²C3 SCL、I²S0 SDO1 | 可用 |
| 18 | GPIO24 | 下拉 | I²S0 SDI2 | 可用 |
| 22 | GPIO25 | 下拉 | I²S0 SDO2、MIC CLK | 可用 |
| 37 | GPIO26 | 下拉 | I²S0 SDI3、MIC DAT0 | 可用 |
| 13 | GPIO27 | 下拉 | I²S0 SDO3、MIC DAT1 | 可用 |

保留引脚：

| 物理针脚 | BCM GPIO | 用途 | 策略 |
| ---: | ---: | --- | --- |
| 27 | GPIO0 | HAT ID EEPROM SDA | 保留，不分配 |
| 28 | GPIO1 | HAT ID EEPROM SCL | 保留，不分配 |

电源和地线请参考 Raspberry Pi 40 针标准排针图；它们不是 GPIO。

## 外设扩展建议

为降低扩展板之间的冲突，优先按标准总线引脚分配：

| 外设 | 建议 GPIO | 物理针脚 | 当前状态 |
| --- | --- | --- | --- |
| I²C1 | GPIO2、GPIO3 | 3、5 | 未启用，可分配 |
| UART0 | GPIO14、GPIO15 | 8、10 | 未启用，可分配 |
| UART0 流控 | GPIO16、GPIO17 | 36、11 | 未启用，可分配 |
| SPI0 | GPIO7 至 GPIO11 | 26、24、21、19、23 | 未启用，可分配 |
| I²S0 | GPIO18 至 GPIO21 | 12、35、38、40 | 未启用，可分配 |
| PWM | GPIO12、GPIO13，或 GPIO18、GPIO19 | 32、33，或 12、35 | 未启用，可分配 |

启用标准接口时，可在 `/boot/firmware/config.txt` 中增加相应配置：

```ini
# I²C1：GPIO2/3
dtparam=i2c_arm=on

# SPI0：GPIO7-11
dtparam=spi=on

# UART0：GPIO14/15
enable_uart=1
```

修改后需要重启，并重新运行本文的检查命令。启用接口后，应立即更新下面的资源登记表，不能再把对应引脚当作普通 GPIO 使用。

## GPIO 资源登记表

新增硬件前先在此登记。状态统一使用 `空闲`、`预留`、`占用`；同一 GPIO 只能有一个输出驱动方。

| 功能/模块 | GPIO | 物理针脚 | 方向/复用 | 状态 | 备注 |
| --- | --- | --- | --- | --- | --- |
| HAT ID EEPROM | GPIO0、GPIO1 | 27、28 | I²C0 | 预留 | 系统保留 |
| 待分配 | GPIO2-GPIO27 | 见映射表 | GPIO | 空闲 | 2026-10-13 实机检查 |

添加模块时建议记录：

1. 模块名称及负责人；
2. BCM GPIO 编号和物理针脚编号；
3. 输入、输出、上拉、下拉或复用功能；
4. 电压、峰值电流以及是否需要电平转换；
5. 对应设备树 overlay 和驱动名称；
6. 分配日期、测试结果和释放日期。

## 检查命令

每次修改设备树或连接新扩展板后执行：

```bash
# 型号
tr -d '\000' < /proc/device-tree/model

# GPIO 控制器及内核占用者
gpioinfo

# 40 针排针相关 GPIO 的实际复用、上下拉和电平
pinctrl get 0-27

# 查询可选复用功能
pinctrl funcs 0-27

# 当前设备树参数和 overlays
grep -E '^[[:space:]]*(dtparam|dtoverlay|enable_uart)' /boot/firmware/config.txt
```

不要使用 `pinctrl set` 做持久配置；它会绕过内核驱动直接修改寄存器。持久配置应通过设备树 overlay 或应用程序所使用的 GPIO API 完成。

## 电气安全

- GPIO 逻辑电平为 **3.3 V**，不支持 5 V 输入；
- 不要从单个 GPIO 直接驱动电机、继电器、大功率 LED 等负载；
- 感性负载应使用驱动器件和续流二极管，并与开发板共地；
- 上电前检查输入输出方向，避免两个推挽输出直接相连；
- GPIO 默认上下拉状态可能在启动阶段变化，关键外设应使用外部电阻保证安全状态；
- 修改接线前先断电，并在通电前确认 3.3 V、5 V 和 GND 没有短路。

## 网络快照

以下地址来自早期 `ifconfig` 记录，仅用于排障参考，可能因 DHCP 或网络共享配置而变化：

| 接口 | 地址/标识 |
| --- | --- |
| Ethernet MAC | `2c:cf:67:ce:d8:1c` |
| Wi-Fi IPv4 | `10.203.184.202/17` |
| Wi-Fi MAC | `2c:cf:67:ce:d8:1d` |
| SSH 直连地址 | `192.168.137.2` |
