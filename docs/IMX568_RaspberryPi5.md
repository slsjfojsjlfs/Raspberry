# Raspberry Pi 5 + VC Sony IMX568 使用说明

> 基于 [VC-MIPI-modules/vc_mipi_raspi](https://github.com/VC-MIPI-modules/vc_mipi_raspi)，结合本机实测终端输出整理。
> 状态：**驱动已安装、IMX568 已识别、RAW8 单帧文件已生成并验证大小；软件触发和外部触发尚未实测。**

## 1. 已验证的硬件与系统环境

| 项目 | 当前配置 / 结果 |
| --- | --- |
| 主板 | Raspberry Pi 5 |
| 相机 | Vision Components Sony IMX568，模块 ID `0x0568`，REV `0006` |
| 摄像头接口 | CAM0 |
| 操作系统 | Debian GNU/Linux 13 (Trixie)，13.7 |
| CPU 架构 | `aarch64` |
| 内核 | `6.18.50+rpt-rpi-2712` |
| 内核头文件 | `linux-headers-6.18.50+rpt-rpi-2712`，已安装 |
| V4L2 工具 | `v4l2-ctl 1.30.1` |
| VC MIPI 驱动包 | `vc-mipi-driver-bcm2712 0.7.0` |
| DKMS | 在当前 `rpi-2712` 内核下 `installed`（亦在 `rpi-v8` 内核下安装） |
| MIPI | CAM0，4 lanes，Sony |
| 采集节点 | `/dev/video0` |
| 控制节点 | `/dev/v4l-subdev2`（已实际读取到 IMX568 控制项） |
| 当前视频格式 | `GREY`，8-bit 单色 |
| 分辨率 | `2464 × 2064` |
| 行字节数 / 帧大小 | `2464` / `5085696` 字节 |

**重要边界：** 这里的安装及配置适用于 VC 模组；其他供应商的 IMX568 模组不一定兼容该驱动。

## 2. 关键验证证据

### 2.1 软件包与 DKMS

```bash
dpkg -l | grep vc-mipi
dkms status
find /lib/modules/$(uname -r) -iname '*vc*mipi*.ko*'
```

本机已经得到：

```text
ii  vc-mipi-driver-bcm2712  0.7.0  arm64
vc-mipi-driver-bcm2712/0.7.0, 6.18.50+rpt-rpi-2712, arm64: installed
vc-mipi-driver-bcm2712/0.7.0, 6.18.50+rpt-rpi-v8, arm64: installed
```

并存在三个内核模块：`vc_mipi_core.ko.xz`、`vc_mipi_camera.ko.xz`、`vc_mipi_modules.ko.xz`。

### 2.2 驱动成功识别传感器

```bash
sudo dmesg | grep -Ei 'vc_mipi|imx568|i2c|probe' | tail -80
```

实测日志包括：

```text
SENSOR | SONY IMX568
MODULE | ID: 0x0568 REV: 0006
VC MIPI Core successfully initialized
vc_core_set_num_lanes(): Set number of lanes: 4
rp1-cfe 1f00110000.csi: Using sensor vc_mipi_camera 10-001a for capture
vc_probe(): Probe successful
vc_sen_start_stream(): Start streaming
vc_sen_stop_stream(): Stop streaming
```

### 2.3 RAW8 文件大小匹配

实测：

```bash
stat -c '%s bytes' /home/r/imx568.raw
# 5085696 bytes
```

计算：`2464 × 2064 × 1 = 5,085,696 bytes`。该证据表明已经保存了与当前 V4L2 格式大小匹配的一帧数据，**并不能单凭文件大小证明画面内容正常**；仍建议查看 PNG 图像。

## 3. 全新设备的安装流程（本机已完成，无需重复）

### 3.1 环境与依赖

```bash
cat /etc/os-release
uname -r
uname -m
ls -ld /lib/modules/$(uname -r)/build
v4l2-ctl --version
```

本机对应内核头文件和 V4L2 1.30.1 已齐全。若在另一台设备安装，先确保 APT 更新正常，再安装必要工具：

```bash
sudo apt update
sudo apt install -y dkms build-essential git whiptail v4l-utils
```

如遇 `NOSPLIT` / `NODATA` / `InRelease` 签名验证错误，应优先排查 HTTP 代理、软件源响应、网络认证和 HTTPS 连通性；**不要禁用 APT 签名校验**。

### 3.2 下载并安装驱动包

从 [GitHub Releases](https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases) 下载与 BCM2712 和 ARM64 匹配的 `.deb` 文件，例如 v0.7.0。切换到下载目录并确认文件名：

```bash
ls -lh vc-mipi-driver-bcm2712*.deb
sudo apt install ./vc-mipi-driver-bcm2712*.deb
sudo dkms status
```

当前系统的 v0.7.0 驱动已成功针对 Linux 6.18.50 编译并安装。

## 4. CAM0 设备树配置

文件：`/boot/firmware/config_vc-mipi-driver-bcm2712.txt`。

本机有效设置：

```ini
dtoverlay=vc-mipi-bcm2712-cam0
dtparam=cam0_lanes4
dtparam=cam0_manu_sony
dtparam=cam0_libcamera_off

dtoverlay=vc-mipi-common-memory-contiguous
```

主配置 `/boot/firmware/config.txt` 中已经有：

```ini
include config_vc-mipi-driver-bcm2712.txt
```

检查命令：

```bash
cat /boot/firmware/config_vc-mipi-driver-bcm2712.txt
grep -nE 'vc-mipi|include|camera_auto_detect' /boot/firmware/config.txt
lsmod | grep vc_mipi
```

**CAM1 注意事项：** 原配置文件还启用了 CAM1，日志中 `vc_mipi_camera 11-001a` 报 `Unable to get module I2C client for address 0x10`。如果 CAM1 确实没有接相机，可将 CAM1 的 `dtoverlay` 与 `dtparam` 行注释掉，之后重启。CAM0 的 `10-001a` 已成功识别，此错误不代表 CAM0 失败。

### 4.1 查询节点

```bash
v4l2-ctl --list-devices
ls -l /dev/video* /dev/v4l-subdev* 2>/dev/null
v4l2-ctl -d /dev/video0 --all
v4l2-ctl -d /dev/v4l-subdev2 -L
```

设备节点编号可能随系统及媒体管线变化；本机当前已验证 `/dev/video0` 是 `rp1-cfe-csi2_ch0` 图像采集节点。

## 5. RAW8 单帧采集（已完成）

当前协商的视频格式为：

```text
Width/Height: 2464/2064
Pixel Format: 'GREY' (8-bit Greyscale)
Bytes per Line: 2464
Size Image: 5085696
```

查询：

```bash
v4l2-ctl -d /dev/video0 --get-fmt-video
v4l2-ctl -d /dev/video0 --list-formats-ext
```

**注意：** `--list-formats-ext` 罗列了 RP1 接收器支持的多种格式，不能等同于 IMX568 传感器每种格式均可工作。当前设备协商的 `GREY` 格式已得到验证。

正常连续采集模式下采集一帧：

```bash
v4l2-ctl -d /dev/v4l-subdev2 -c trigger_mode=0

timeout 15s v4l2-ctl -d /dev/video0 \
  --stream-mmap=4 \
  --stream-count=1 \
  --stream-to=/home/r/imx568.raw \
  --verbose

stat -c '%s bytes' /home/r/imx568.raw
```

目标文件大小：`5085696 bytes`（本机已经达到）。

### 5.1 转换为 PNG（建议执行以检查内容）

安装依赖（如果已经安装可跳过）：

```bash
sudo apt install -y python3-numpy python3-opencv
```

保存为 `raw_to_png.py`：

```python
import numpy as np
import cv2

width, height = 2464, 2064
raw_path = '/home/r/imx568.raw'
png_path = '/home/r/imx568.png'

raw = np.fromfile(raw_path, dtype=np.uint8)
expected = width * height
if raw.size != expected:
    raise ValueError(f'RAW 字节数 {raw.size}，预期 {expected}')

image = raw.reshape(height, width)
if not cv2.imwrite(png_path, image):
    raise RuntimeError('PNG 保存失败')

print('已保存:', png_path)
print('min:', image.min(), 'max:', image.max(), 'mean:', image.mean())
```

运行：

```bash
python3 raw_to_png.py
```

仅适用于当前 `GREY`、每像素 1 字节、无行填充的图像；对 RAW10/RAW12 packed 格式不能直接照搬。

### 5.2 连续采集 41 张 PNG（已完成）

脚本位置：

```text
/home/r/Raspberry/Drvier/capture_imx568_41.sh
```

运行：

```bash
/home/r/Raspberry/Drvier/capture_imx568_41.sh
```

脚本固定使用 `/dev/video0` 和 `/dev/v4l-subdev2`，设置连续模式
`trigger_mode=0`，以 `GREY 2464×2064` 在同一次 V4L2 流中连续采集 41 帧，
并转换为：

```text
/home/r/Raspberry/Image/image_temp_result/imx568_001.png
...
/home/r/Raspberry/Image/image_temp_result/imx568_041.png
```

每次运行都会先清空并重建本次结果内容，仅清理
`/home/r/Raspberry/Image/image_temp_result`，不会影响 `Image` 下的其他目录。
目录中还会生成 `capture_info.txt`，记录拍摄时间、设备节点、分辨率、格式、
曝光、增益和触发模式。脚本会核对 41 帧 RAW 总字节数、PNG 数量和依赖，
并使用文件锁避免两个采集任务同时访问相机。

本机已连续执行两次验证：每次均生成 41 张 `2464×2064` PNG，实测帧间隔
约 `10.386 ms`（约 `96.28 fps`）；第二次运行已确认上一次结果会被清除。

### 5.3 带逐帧时间戳和大小日志的 41 张采集

脚本位置：

```text
/home/r/Raspberry/Drvier/capture_imx568_41_detailed.sh
```

运行：

```bash
/home/r/Raspberry/Drvier/capture_imx568_41_detailed.sh
```

脚本在同一次 V4L2 stream 中先丢弃 1 张启动预热帧，再连续保存 41 帧，并从 `v4l2-ctl --verbose` 读取每一帧真实的内核 buffer 时间戳、sequence 和 `bytesused`。时间戳来源是 `CLOCK_MONOTONIC` 的帧结束时间，脚本通过采集前的时钟锚点将其转换为带时区的系统时间，不使用平均帧率反推时间戳。

结果目录：

```text
/home/r/Raspberry/Image/image_temp_result/
├── imx568_001.png ... imx568_041.png
├── capture_detailed.log
├── capture_report.json
├── frames.csv
└── capture_info.txt
```

日志内容包括：

- 采集命令总耗时、第一帧至最后一帧跨度和整个脚本总耗时；
- 40 个实际帧间隔及其平均值、最小值、最大值；
- 每帧的带时区时间戳、V4L2 sequence 和 buffer 编号；
- 每帧 RAW 字节数、PNG 文件大小、文件名和 SHA-256；
- 分辨率、像素格式、设备节点和时间戳来源。
- 系统时钟是否报告为 NTP 已同步；绝对时间依赖板端时钟，而帧间隔不受校时影响。

`capture_detailed.log` 供人工查看，`capture_report.json` 供程序读取，`frames.csv` 便于表格分析。与原脚本一致，每次运行前仅清空固定的 `image_temp_result` 目录，并通过文件锁阻止两个任务同时访问相机。

### 5.4 保存 41 个独立 RAW8 文件及详细日志

脚本位置：

```text
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh
```

运行：

```bash
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh
```

脚本先丢弃 1 张预热帧，再在同一个 V4L2 stream 中保存 41 张原始数据：

```text
/home/r/Raspberry/Image/image_temp_result/
├── imx568_001.raw ... imx568_041.raw
├── capture_detailed.log
├── capture_report.json
├── frames.csv
└── capture_info.txt
```

每个 RAW 文件是 `GREY 2464×2064` 的无文件头 RAW8 数据，理论且实测期望大小均为 `2464×2064=5,085,696` 字节。读取示例：

```python
import numpy as np

image = np.fromfile("imx568_001.raw", dtype=np.uint8).reshape(2064, 2464)
```

日志记录采集总时间、第一帧到最后一帧的跨度、40 个实际帧间隔、每帧内核时间戳、文件大小、V4L2 sequence 和 SHA-256。脚本不执行 PNG 编码，适合保留算法输入的原始像素值。

拍摄张数和时间间隔配置：

```bash
# 默认：41 张，间隔 0 表示使用相机自动/最大帧率
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh

# 示例：拍摄 100 张，目标间隔 50 ms
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh \
  --count 100 \
  --interval-ms 50

# 查看参数说明
/home/r/Raspberry/Drvier/capture_imx568_41_raw_detailed.sh --help
```

参数说明：

| 参数 | 含义 | 默认值 |
| --- | --- | ---: |
| `-n`, `--count N` | 要保存的 RAW 帧数，正整数 | 41 |
| `-i`, `--interval-ms MS` | 目标帧间隔，单位毫秒；支持小数，0 表示自动/最大帧率 | 0 |

非零间隔会换算为驱动 `frame_rate` 的 mHz 值。若目标超出当前 IMX568 模式支持范围，驱动会拒绝设置并停止脚本。报告同时保存 `requested_interval_ms`、`configured_frame_rate_millihz`、`configured_interval_ms` 和逐帧实测 `frame_interval_ms`。运行结束时自动恢复 `frame_rate=0`，因此配置不会遗留给下一次采集。

## 6. IMX568 实际 V4L2 控制项

查询：

```bash
v4l2-ctl -d /dev/v4l-subdev2 -L
```

本机读取到：

| 控制项 | 范围 / 当前值 | 说明 |
| --- | --- | --- |
| `exposure` | 1–83600633；当前 10000 | 曝光控制；本机日志显示单位 µs |
| `analogue_gain` | 0–48000；当前 0 | 模拟增益；日志以 mdB 报告增益 |
| `black_level` | 0–100000；当前 5859 | 黑电平，按驱动定义的相对单位 |
| `trigger_mode` | 0、1、2、3、4 | Off / External / Pulse Width / Self / Single |
| `single_trigger` | button，write-only | 软件单帧触发命令 |
| `io_mode` | 0–5 | Trigger/Flash 极性配置 |
| `frame_rate` | 0–90563；当前 0 | 单位 mHz，上限约 90.563 fps（当前全分辨率 RAW8 模式） |
| `binning_mode` | 当前 0 | 实际支持值须结合模组模式和驱动验证 |
| `sensor_info` | `IMX568 REV.0006` | 模块型号 |

示例：

```bash
# 设置 5ms 曝光
v4l2-ctl -d /dev/v4l-subdev2 -c exposure=5000

# 设置模拟增益（以本机驱动控制定义为准）
v4l2-ctl -d /dev/v4l-subdev2 -c analogue_gain=6000

# 查询关键值
v4l2-ctl -d /dev/v4l-subdev2 -C exposure,analogue_gain,trigger_mode,io_mode
```

**不要将其他传感器或 libcamera 下的曝光、增益单位直接套用此接口。**

## 7. 软件单帧触发（待实测）

VC 官方文档定义 `trigger_mode=4` 为 Single 模式，并用 `single_trigger=1` 请求拍摄。步骤：

**终端 A：** 切换到 Single 模式并启动帧接收（会等待触发）：

```bash
v4l2-ctl -d /dev/v4l-subdev2 -c trigger_mode=4

timeout 30s v4l2-ctl -d /dev/video0 \
  --stream-mmap=4 \
  --stream-count=1 \
  --stream-to=/home/r/single.raw \
  --verbose
```

**终端 B：** 等终端 A 开始等待后，发送单次触发：

```bash
v4l2-ctl -d /dev/v4l-subdev2 -c single_trigger=1
```

**检查：**

```bash
stat -c '%s bytes' /home/r/single.raw
```

预期在当前 RAW8 设置下单帧为 `5085696 bytes`，但**软件触发尚未在本机验证**。最后恢复：

```bash
v4l2-ctl -d /dev/v4l-subdev2 -c trigger_mode=0
```

如遇超时，检查相机是否已进入 STREAMON、控制节点是否被其他进程占用及 `dmesg`。要获得严格的启动/触发时序，应改为原生 V4L2 程序做缓冲队列和状态同步。

## 8. 外部触发（待实测）

外部触发使用 `trigger_mode=1`。本机 `io_mode=0` 表示 Flash 关闭且触发为高有效；如需要低有效，可按实际硬件逻辑检查 `io_mode=3`。

**必须先核对 VC IMX568 对应硬件手册的 Trigger 引脚、电压、极性、脉宽及接地/隔离要求。不要直接连接未经确认的 3.3 V、5 V 或 PLC 24 V 信号。**

**终端 A：**

```bash
v4l2-ctl -d /dev/v4l-subdev2 -c io_mode=0
v4l2-ctl -d /dev/v4l-subdev2 -c trigger_mode=1

timeout 60s v4l2-ctl -d /dev/video0 \
  --stream-mmap=4 \
  --stream-count=1 \
  --stream-to=/home/r/external.raw \
  --verbose
```

在采集进程开始等待后，由外部设备发送**符合硬件规格**的一次触发脉冲。

检查：

```bash
stat -c '%s bytes' /home/r/external.raw
```

恢复默认触发模式：

```bash
v4l2-ctl -d /dev/v4l-subdev2 -c trigger_mode=0
```

另有 `trigger_mode=2`（Pulse Width）和 `trigger_mode=3`（Self），均在本机控制菜单中可见，但本文未开展实际测试。对于连续高速、严格时序的项目，推荐原生 C/C++ V4L2 缓冲采集、队列复用和丢帧检测，而不是反复启动命令行进程。

## 9. 4-lane IMX568 日志报告的模式帧率上限

| 格式 | 全分辨率（binning 0） | 2×2 Binning（binning 1） |
| --- | ---: | ---: |
| RAW8 | 90.563 fps | 316.957 fps |
| RAW10 | 79.214 fps | 268.600 fps |
| RAW12 | 67.303 fps | 233.045 fps |

这些是驱动在初始化日志中报告的模式理论上限，**不是已经测得的持续存盘帧率**。官方文档的分辨率参考：无 Binning `2464×2064`，2×2 Binning `1216×1032`。启用 Binning 后，Pregius S IMX56x 系列可能输出单色图像。

## 10. 故障排查

```bash
# 当前模块与 DKMS
sudo dkms status
lsmod | grep vc_mipi

# 视频设备及控制
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --get-fmt-video
v4l2-ctl -d /dev/v4l-subdev2 -L

# 驱动探测、I2C 和采集日志
sudo dmesg | grep -Ei 'vc_mipi|imx568|probe|i2c' | tail -100
```

如已克隆项目，可以运行官方脚本：

```bash
cd ~/vc_mipi_raspi
./tools/self_check.sh --no-stream
# 确保硬件/配置稳定后再运行完整流测试：
./tools/self_check.sh
```

- 找不到 sensor：检查 CAM0 设备树、`cam0_manu_sony`、lane 数量、排线和供电。
- `I2C client for address 0x10`：先看错误归属哪个总线；本机 CAM1（`11-001a`）报错，CAM0（`10-001a`）探测成功。
- 有 RAW 文件但无图像：核对格式、帧大小、像素分布、镜头盖、曝光和增益。
- 软件触发无帧：确认 `trigger_mode=4` 和正在等待帧的流接收程序。
- 外部触发无帧：核对硬件引脚、电平、极性、脉宽及流接收程序。

## 11. 完成状态清单

- [x] Debian 13 ARM64 / Linux 6.18.50 头文件齐全
- [x] VC MIPI 0.7.0 安装，当前内核 DKMS `installed`
- [x] 4-lane CAM0 Sony IMX568 驱动探测成功
- [x] `/dev/video0` 上 `GREY`、2464×2064 格式正确
- [x] 生成 `imx568.raw`，文件大小为 5,085,696 字节
- [x] `/dev/v4l-subdev2` 中确认 Single / External / Pulse Width / Self 控制项
- [ ] PNG 画面目视检查或图像统计确认
- [ ] 软件单帧触发采集实测
- [ ] 外部硬件触发采集实测
- [ ] 高帧率、长时间运行与丢帧验证

## 12. 官方参考资料

- [vc_mipi_raspi 仓库](https://github.com/VC-MIPI-modules/vc_mipi_raspi)
- [驱动 Releases](https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases)
- [Trigger Modes](https://github.com/VC-MIPI-modules/vc_mipi_raspi/blob/main/docs/trigger_mode.md)
- [IO Modes](https://github.com/VC-MIPI-modules/vc_mipi_raspi/blob/main/docs/io_mode.md)
- [Binning Modes](https://github.com/VC-MIPI-modules/vc_mipi_raspi/blob/main/docs/binning_mode.md)
- [Libcamera 支持](https://github.com/VC-MIPI-modules/vc_mipi_raspi/blob/main/docs/libcamera.md)

---

*本 README 根据实际终端日志与此前讨论整理；未实际运行过的触发功能明确标记为待验证。*
