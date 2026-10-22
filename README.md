# Raspberry Pi 5 IMX568 开发工程

本工程汇总 Raspberry Pi 5、Vision Components IMX568 相机、GPIO、图像传输和光谱重建相关代码。目录按“硬件采集、算法、工具、文档、依赖包、运行数据”分离，便于后续扩展而不把生成文件混入源码。

## 目录结构

```text
Raspberry/
├── camera/                         # IMX568 采集脚本
├── algorithms/
│   └── spectral-reconstruction/   # v14-r8 CPU 光谱重建实现
├── scripts/
│   └── transfer/                  # Windows 与树莓派之间的图像传输工具
├── docs/
│   ├── IMX568_RaspberryPi5.md     # 相机驱动、采集与故障排查
│   ├── RaspberryPi5_development.md# GPIO、设备树和项目操作说明
│   └── algorithms/RKNN.md         # 原始算法与迁移依据
├── packages/vc-mipi/              # 已验证的离线驱动安装包
└── data/                           # 本地运行数据，默认不提交 Git
```

## 相机采集

板端已验证的默认设备：

```text
视频节点：/dev/video0
控制节点：/dev/v4l-subdev2
格式：GREY RAW8
分辨率：2464×2064
单帧大小：5,085,696 字节
```

主要脚本：

| 脚本 | 用途 |
| --- | --- |
| `camera/capture_imx568_41.sh` | 连续采集 41 帧并转换为 PNG |
| `camera/capture_imx568_41_detailed.sh` | PNG 采集并生成逐帧时间和大小日志 |
| `camera/capture_imx568_41_raw_detailed.sh` | RAW8 采集，支持配置张数和目标间隔 |

RAW 可配置版本示例：

```bash
# 默认：41 张、相机自动/最大帧率
./camera/capture_imx568_41_raw_detailed.sh

# 100 张、目标帧间隔 50 ms
./camera/capture_imx568_41_raw_detailed.sh --count 100 --interval-ms 50
```

脚本的板端结果目录为 `/home/r/Raspberry/Image/image_temp_result`。每次采集会清理该固定目录中的上一次结果。目标间隔通过相机 `frame_rate` 设置，真实间隔以 `capture_report.json` 中的逐帧时间戳为准。

详细说明见 [IMX568 使用文档](docs/IMX568_RaspberryPi5.md)。

## 光谱重建

`algorithms/spectral-reconstruction` 是针对 Raspberry Pi 5 的 v14-r8 CPU/NumPy 实现：

- 输入为每个像素 41 维响应；
- 构造 861 维上三角二次特征；
- 输出 400–800 nm、间隔 4 nm 的 101 维光谱；
- 支持磁盘映射、分块推理、暗场/白场校正和结果哈希；
- 输出统一位于板端 `/home/r/Raspberry/Result`。

板端运行：

```bash
cd /home/r/Raspberry/Algorithm
python3 run_reconstruction.py --config config.json
```

算法公式、权重格式、配置和验收条件见[光谱重建说明](algorithms/spectral-reconstruction/README.md)。原始 RKNN 迁移依据见 [RKNN 算法记录](docs/algorithms/RKNN.md)。

## 图像上传与下载

在 Windows PowerShell 中从仓库根目录运行：

```powershell
# data/Image -> /home/r/Raspberry/Image
.\scripts\transfer\upload-images.cmd

# /home/r/Raspberry/Image -> data/Image/raspberry_image
.\scripts\transfer\download-images.cmd
```

脚本使用 Windows OpenSSH，并将本机 `known_hosts` 写入被忽略的 `.state/ssh`，不会把 SSH 密码或主机记录提交到仓库。

## 本地数据与版本控制

现有图像已复制到 `data/Image`，但该目录内容属于采集产物，不进入 Git。以下内容也被忽略：

- RAW、PNG/JPEG 采集结果；
- Python `__pycache__` 和虚拟环境；
- 本机 SSH 状态；
- 生产配置、采集 manifest、权重和算法结果。

可提交的配置必须使用 `*.example.json`，不要提交密码、私钥、生产标定数据或未经确认许可的大文件。

## 离线驱动包

`packages/vc-mipi` 保存本机已经验证的 BCM2712 ARM64 安装包。具体版本、哈希和安装边界见该目录说明。驱动安装会修改系统和启动配置，操作前请阅读 [IMX568 使用文档](docs/IMX568_RaspberryPi5.md)。

## 开发约定

- 相机采集代码放入 `camera/`；
- 新算法以独立子目录放入 `algorithms/`，同时提供 README 和示例配置；
- Windows/板端辅助工具放入 `scripts/`；
- 硬件、接口和验收记录放入 `docs/`；
- 生成数据只写入 `data/` 或板端 Result/Image 目录；
- 新增 GPIO 外设前更新 [Raspberry Pi 5 开发说明](docs/RaspberryPi5_development.md)中的资源登记表。

## 当前限制

- 开发板此前报告 NTP 未同步，绝对时间戳依赖板端系统时钟；帧间隔使用内核单调时钟，不受校时影响。
- 光谱模型已经完成生产权重执行验证，但真实 IMX568 光谱精度仍需 41 档偏压、暗场/白场和光谱仪真值验收。
- 仓库未附带生产权重和标定数据。
