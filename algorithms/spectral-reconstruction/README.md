# Raspberry Pi 5 光谱重建算法

本目录将 [`docs/algorithms/RKNN.md`](../../docs/algorithms/RKNN.md) 描述的 v14-r8 光谱重建算法迁移到 Raspberry Pi 5。Pi 5 不具备 Rockchip NPU，因此采用 CPU、NumPy 和 OpenBLAS 执行 float32 推理，不依赖 RKNN Toolkit、`.rknn` 模型或 `librknnrt.so`。

板端程序统一位于 `/home/r/Raspberry/Algorithm`，所有结果统一写入 `/home/r/Raspberry/Result`。

## 部署状态

已完成：

- 生产 NPZ 权重和原 C++ `V14R8B2` 权重二进制部署；
- 启动时逐元素核对 NPZ 与 BIN 的线性项、二次项、偏置和通道索引；
- 从 BIN 读取原始 `101×3` RGB 转换矩阵；
- 41 通道 manifest、文件、通道索引及偏压字段校验；
- PNG、单通道图像、`.npy` 和未打包 RAW 输入；
- scale 或逐通道暗场/白场归一化；
- 磁盘映射的 `(H*W, 41)` 输入、分块推理和 `(H*W, 101)` 光谱输出；
- 400–800 nm 波长轴、RGB 预览、SHA-256 及耗时报告；
- 合成权重数值自测和真实生产权重执行验证。

当前不能把相机实拍结果标记为“已完成光谱精度验收”，因为仍缺少：IMX568 与模型训练严格对应的 41 档偏压表、各偏压的暗场/白场和训练期归一化参数、真实样本的参考光谱真值。

`capture_imx568_41.sh` 当前是在同一设置下连续采集 41 帧，只能验证连续采集稳定性，不能替代模型要求的 41 个偏压通道。程序默认拒绝未审核的 manifest，以避免生成物理含义错误的光谱。

## 板端目录

```text
/home/r/Raspberry/Algorithm/
├── README.md
├── source_algorithm_readme.md
├── spectral_reconstruction.py
├── run_reconstruction.py
├── self_test.py
├── validate_production.py
├── config.example.json
├── config.json
├── capture_manifest.example.json
├── capture_manifest.json
├── weights/
│   ├── spectral_recon_v14_quadratic_rank8_weights.npz
│   └── spectral_recon_v14_quadratic_rank8_cpp.bin
└── reference/
    ├── colorchecker_x41.npy
    ├── board_quadratic_cpu_benchmark.py
    ├── export_v14_rank8_cpp.py
    └── v14_rank8_cpu.cpp

/home/r/Raspberry/Result/
├── selftest/report.json
├── reference_validation/
│   ├── report.json
│   ├── colorchecker_spectrum_101.npy
│   ├── wavelengths_nm.npy
│   └── colorchecker_rgb.png
└── run_YYYYMMDD_HHMMSS/
```

## 算法

每个像素输入为 41 维响应 `x`。先按 `0 <= i <= j < 41` 构造 861 维上三角二次项：

```text
q(x) = [x_i * x_j]
```

随后计算：

```text
y = clip(
    x @ linear_weight.T
    + (q(x) @ quadratic_right.T) @ quadratic_left.T
    + bias,
    0,
    1
)
```

| 名称 | 形状 |
| --- | --- |
| 输入 `x` | `(N, 41)` |
| `linear_weight` | `(101, 41)` |
| `quadratic_right` | `(8, 861)` |
| `quadratic_left` | `(101, 8)` |
| `bias` | `(101,)` |
| 输出 `y` | `(N, 101)` |

输出通道 `c` 对应 `400 + 4*c nm`。低秩分解避免保存完整的 861×101 二次权重；程序只在每个 `chunk_size` 分块中临时生成二次特征。

## 权重与完整性

正式运行同时加载：

```text
weights/spectral_recon_v14_quadratic_rank8_weights.npz
weights/spectral_recon_v14_quadratic_rank8_cpp.bin
```

当前部署文件 SHA-256：

```text
NPZ cfa2f3f27229b4d9492fd29f15d684bae28ff8a023c8ed1fccdc42cf3a503161
BIN 0cca027e9b45029f012ed3fa542eec326eddf7e37a21fb699edebe9f76b2b26c
```

NPZ 包含模型参数；BIN 是原 C++ 导出文件，另包含 RGB 矩阵。加载器会核对两者共有参数，任何差异、形状错误、截断或格式错误都会停止运行。

## 采集 manifest

`capture_manifest.json` 必须恰好包含 41 项：

```json
{
  "production_ready": true,
  "frames": [
    {"channel_index": 0, "bias": 0.0, "file": "imx568_001.png"}
  ]
}
```

要求：

- `channel_index` 无重复地覆盖 0–40；
- `bias` 是实际偏压，不能用帧序号代替；
- 41 个文件是相同尺寸的单通道图像；
- 通道顺序与训练权重一致；
- 只有完成硬件及顺序核对后，才能把 `production_ready` 改为 `true`。

未打包 Mono12/16 RAW 可在配置中增加：

```json
"raw": {"width": 4032, "height": 3036, "dtype": "<u2"}
```

## 归一化

示例配置对 8-bit 图像执行机械缩放：

```json
"normalization": {
  "mode": "scale",
  "offset": 0.0,
  "scale": 255.0,
  "clip": true
}
```

生产环境优先使用逐偏压暗场/白场：`(scene - dark) / (white - dark + epsilon)`。此时将模式设为 `dark_white`，并在每个 manifest 项中填写 `dark_file` 和 `white_file`。归一化必须与训练阶段一致。

## 运行与输出

确认 manifest 和配置后运行：

```bash
cd /home/r/Raspberry/Algorithm
python3 run_reconstruction.py --config config.json
```

每次运行创建：

```text
/home/r/Raspberry/Result/run_YYYYMMDD_HHMMSS/
├── scene_x41.npy
├── spectrum_101.npy
├── wavelengths_nm.npy
├── reconstructed_rgb.png
└── report.json
```

全分辨率 2464×2064 时，`scene_x41.npy` 约 0.78 GiB，`spectrum_101.npy` 约 1.91 GiB；运行前需检查磁盘空间。RGB 只用于快速目视检查，不能代替光谱精度评价。

## 验证

```bash
cd /home/r/Raspberry/Algorithm

# 合成权重公式自测
python3 self_test.py
cat /home/r/Raspberry/Result/selftest/report.json

# 生产权重与原参考输入验证
python3 validate_production.py
cat /home/r/Raspberry/Result/reference_validation/report.json
```

2026-10-15 板端生产权重验证结果：

- NPZ/BIN 共有参数逐元素一致；
- 输入 `24×41`，输出 `24×101`；
- 输出范围 `[0.0, 0.4276449382]`，均值 `0.0482677817`；
- 输出 SHA-256：`39180c904ac096e1cdb0b6effe45c83a80333b776dd29b68176ae145d410020f1`；
- 已生成 `colorchecker_rgb.png`。

原工程未附带该输入对应的真值光谱，因此这项测试验证生产权重可执行性、文件完整性和两个权重格式的一致性，不是算法精度测试。

## 最终验收条件

1. 固化并记录 41 档真实偏压及采集顺序；
2. 采集每档偏压的暗场、白场和至少一个实景；
3. 用同一批 `x41` 对比原实现与树莓派输出，记录 MAE 和最大绝对误差；
4. 用光谱仪真值计算实际光谱误差；
5. 检查范围、NaN/Inf、重复运行一致性及 RGB 预览；
6. 保存报告中的输入、manifest、NPZ 和 BIN 哈希。

在完成上述步骤前，正确状态是：生产模型迁移及执行验证已完成，实拍光谱精度尚待标定和真值验收。
