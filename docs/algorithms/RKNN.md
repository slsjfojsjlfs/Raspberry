# RKNN 光谱重建数据处理算法

本文整理自 `G:\RKNN` 中当前可运行代码，说明 41 帧灰度响应如何转换为 101 维光谱及 RGB 图像，供树莓派端迁移和后续维护使用。

> 分析基线：2026-10-17。当前推荐的高精度光谱重建是 **v14-r8 CPU float32**；真正使用 RKNN NPU 的 **v19 混合方案仅适用于 RK3588**。Raspberry Pi 5 使用 Broadcom BCM2712，不能直接运行 RKNN 模型。

## 1. 数据流

```text
41 帧 Mono12 RAW
  -> 完整性和帧序检查
  -> 暗场/白场校正、ROI 或缩放
  -> (41,H,W) -> (H,W,41) -> (H*W,41) float32
  -> v14-r8 低秩二次回归
  -> (H*W,101) 光谱，400~800 nm，步长 4 nm
  -> CIE 1931 XYZ -> 线性 sRGB -> gamma
  -> (H,W,3) uint8 图像
```

阶段之间应使用明确的数据文件和元数据交接，不要把采集、校正、推理和显示写成不可单测的单个程序。

## 2. 输入数据约定

### 2.1 相机 RAW

海康相机当前采集格式为未打包 Mono12：

- 分辨率：`4032 x 3036`；
- 存储类型：小端 `uint16`，即 NumPy `dtype="<u2"`；
- 单帧字节数：`4032 * 3036 * 2 = 24,482,304`；
- 一轮必须恰好 41 帧，并与 41 个偏压档位一一对应；
- 传感器有效 ADC 位深为 10 bit，16 bit 只是存储容器。

读取单帧：

```python
frame = np.fromfile(path, dtype="<u2").reshape(3036, 4032)
```

进入算法前必须拒绝以下数据：缺帧、重复帧、帧号跳变、错误字节数、丢包、曝光或增益在一轮内变化。偏压顺序必须来自显式配置表，不能仅依赖文件名排序。

### 2.2 校正与重排

建议对每个偏压通道分别执行暗场/白场校正：

```text
corrected[k,y,x] =
    (scene[k,y,x] - dark[k,y,x]) /
    (white[k,y,x] - dark[k,y,x] + epsilon)
```

然后执行：

```python
# frames: (41, H, W)
x41 = np.moveaxis(frames, 0, -1)   # (H, W, 41)
x41 = np.ascontiguousarray(x41.reshape(-1, 41), dtype="<f4")
np.save("scene_x41.npy", x41)
```

若需要 ROI 或缩放，应对 41 个通道使用完全相同的空间参数。模型输入约定为：

| 属性 | 要求 |
| --- | --- |
| shape | `(N, 41)`，其中 `N = H * W` |
| dtype | little-endian `float32` |
| memory order | C contiguous |
| 通道顺序 | 与训练使用的 41 档偏压表一致 |
| 数值范围 | 必须与训练数据的校正和归一化方案一致 |

仓库目前尚未提供正式的海康 RAW → x41 校正工具，因此上述校正属于迁移接口要求，不应声称已经完成端到端验证。

## 3. 推荐算法：v14-r8 CPU 二次回归

### 3.1 数学模型

对每个像素的 41 维响应 `x`，先构造包含对角线的上三角二次项：

```text
q(x) = [x_i * x_j | 0 <= i <= j < 41]
dim(q) = 41 * 42 / 2 = 861
```

完整模型为：

```text
y = clip(x @ W_linear^T + (q(x) @ R^T) @ L^T + bias, 0, 1)
```

各张量形状：

| 张量 | 形状 | 含义 |
| --- | --- | --- |
| `x` | `(N,41)` | 像素的 41 档响应 |
| `q(x)` | `(N,861)` | 上三角二次特征 |
| `W_linear` | `(101,41)` | 线性权重 |
| `R` | `(8,861)` | 二次权重右因子 |
| `L` | `(101,8)` | 二次权重左因子 |
| `bias` | `(101,)` | 偏置 |
| `y` | `(N,101)` | 101 点重建光谱 |

rank=8 的 SVD 分解把二次部分从一次 `861 -> 101` 大矩阵乘法改为 `861 -> 8 -> 101`，显著减少计算量和权重体积。输出第 `c` 个通道对应：

```text
wavelength_nm[c] = 400 + 4*c,  c = 0..100
```

### 3.2 NumPy 参考实现

```python
def reconstruct_x41(x, weights, chunk_size=4096):
    x = np.asarray(x, dtype=np.float32).reshape(-1, 41)
    pair_i = weights["pair_i"]
    pair_j = weights["pair_j"]
    linear = weights["linear_weight"].astype(np.float32)
    right = weights["quadratic_right"].astype(np.float32)
    left = weights["quadratic_left"].astype(np.float32)
    bias = weights["bias"].astype(np.float32)

    result = []
    for start in range(0, len(x), chunk_size):
        part = x[start:start + chunk_size]
        quadratic = part[:, pair_i] * part[:, pair_j]
        y = part @ linear.T
        y += (quadratic @ right.T) @ left.T
        y += bias
        result.append(np.clip(y, 0.0, 1.0))
    return np.concatenate(result, axis=0)
```

实际权重文件也可能使用键名 `q_right`、`q_left`，加载器应兼容两组名称并检查所有形状。

### 3.3 分块与内存

不要一次为全分辨率图像创建 `(H*W,861)` 二次特征。以 `chunk_size=4096` 为例，中间二次缓冲约为：

```text
4096 * 861 * 4 bytes ~= 13.5 MiB
```

处理每个分块后立刻复用缓冲区。C++ 实现进一步采用 OpenBLAS `SGEMM`、预分配缓冲区和 OpenMP 分块并行。树莓派迁移时应先保证与 NumPy 结果一致，再调节 BLAS 线程数和 chunk 大小。

### 3.4 已记录结果

原 RK3588 板端记录中，v14-r8 的测试集 MSE 约为 `5.0808e-6`，512×512 纯推理约 `0.20 s`。这些是 RK3588/OpenBLAS 的历史结果，不能直接作为 Raspberry Pi 5 的性能结论，必须重新测试。

## 4. 光谱转 RGB

101 维输出覆盖 400~800 nm、间隔 4 nm。代码将 CIE 1931 2° 匹配函数和 XYZ→sRGB 矩阵预合并为 `(101,3)` 的线性矩阵：

```text
rgb_linear = spectrum101 @ rgb_matrix
```

其中离散积分步长为 4 nm，归一化系数使用 1 nm CMF 的 ȳ 总和。随后：

1. 使用整幅线性 RGB 的 `99.5%` 分位数进行亮度缩放；
2. 截断到 `[0,1]`；
3. 执行标准 sRGB gamma；
4. 乘 255、四舍五入并转为 `uint8`。

```python
scale = np.percentile(rgb_linear, 99.5)
if scale > 1e-12:
    rgb_linear /= scale
rgb_linear = np.clip(rgb_linear, 0.0, 1.0)
rgb = np.where(
    rgb_linear <= 0.0031308,
    12.92 * rgb_linear,
    1.055 * np.power(rgb_linear, 1.0 / 2.4) - 0.055,
)
rgb8 = np.round(np.clip(rgb, 0, 1) * 255).astype(np.uint8)
```

99.5% 分位缩放依赖整幅图像，不适合要求跨场景绝对亮度一致的测量任务；此时应固定曝光/白点策略，并把配置写入输出元数据。

## 5. RKNN NPU 路线及树莓派限制

### 5.1 v19 混合校准

仓库中的高精度 RKNN 路线为：

```text
x41
  -> v8-direct FP16 RKNN（固定 batch=256，三 NPU 核并行）
  -> 201 维板端特征
  -> concat(201 维特征, 原始 41 维输入) = 242 维
  -> CPU float32 线性校准头
  -> 101 维光谱
```

RKNN Toolkit/Runtime、模型、驱动和 NPU 输出误差共同决定校准结果。更换 RKNN 模型、Runtime 版本或芯片后，必须重新采集板端特征并拟合校准头。历史记录的独立测试集 MSE 为 `3.8573e-6`，512×512 推理约 `15.725 s`。

### 5.2 Raspberry Pi 5

Raspberry Pi 5 没有 Rockchip NPU，以下文件不能原生运行：

- `.rknn` 模型；
- `rknn-toolkit-lite2` 板端推理；
- `librknnrt.so` C API；
- RK3588 三 NPU 核并行脚本。

树莓派迁移应采用 v14-r8 NumPy 或 C++/OpenBLAS 路线。只有目标板是 RK356x/RK3588 等受支持 Rockchip 芯片时，才部署 RKNN Runtime。

### 5.3 不应混用的旧实验

目录还保留 v4 SVD-r64、INT8/INT16、固定 batch 和 21 通道输入实验。这些是历史性能或失败路线，不是当前 41 帧主算法。尤其要避免：

- 把旧模型的 21 维输入接到 41 帧数据；
- 仅在运行时传入大 batch，却仍使用静态 batch=1 模型；
- 对高精度光谱任务使用已明显退化的 INT8 模型；
- 将某块 RK3588 上拟合的硬件校准头复用到另一平台。

## 6. 树莓派实现建议

基础依赖：

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-numpy python3-opencv
python3 -m venv --system-site-packages .venv
source .venv/bin/activate
```

建议目录：

```text
Algorithm/RKNN/
  README.md
  preprocess.py          # RAW检查、校正、ROI/缩放、生成x41
  reconstruct.py         # NumPy v14-r8参考实现
  render_rgb.py          # 101维光谱转RGB
  weights/
    spectral_recon_v14_quadratic_rank8_weights.npz
  tests/
    test_preprocess.py
    test_reconstruct.py
    test_render_rgb.py
```

若追求速度，再增加 C++/OpenBLAS 实现；Python 参考实现应保留为数值基准。

## 7. 必须执行的验证

### 7.1 输入检查

- RAW 数量恰好为 41；
- 每帧尺寸、字节数和格式一致；
- 帧号连续且 `lost_packets=0`；
- 通道 0/20/40 对应预期偏压；
- x41 为 `(H*W,41)`、`float32`、C contiguous；
- 输入和中间结果无 NaN/Inf。

### 7.2 数值一致性

使用同一小批输入比较原实现与树莓派实现：

```python
diff = np.abs(reference - migrated)
print("mae", diff.mean(), "max", diff.max())
```

验收阈值应依据实际权重和参考输出确定。建议至少检查：输出形状 `(N,101)`、范围 `[0,1]`、重复运行确定性，以及 Python/C++ 结果误差。

### 7.3 端到端检查

- 暗场输入应产生合理的低响应；
- 白场分母接近零时不得产生 NaN/Inf；
- 缺帧或顺序错误必须失败退出，禁止静默补帧；
- RGB 图像尺寸必须满足 `N = H * W`；
- 输出报告记录输入文件哈希、偏压表、标定版本、权重版本、尺寸和耗时。

## 8. 原始实现索引

当前分析依据：

- `beagle/rknn/rk3588_v4_svd_lr64/v14_rank8_cpu.cpp`
- `beagle/rknn/rk3588_v4_svd_lr64/board_quadratic_cpu_benchmark.py`
- `beagle/rknn/rk3588_v4_svd_lr64/export_v14_rank8_cpp.py`
- `beagle/rknn/rk3588_v4_svd_lr64/v14_rank8_display_ui.py`
- `beagle/rknn/rk3588_v4_svd_lr64/README.md`
- `beagle/pytorch_1dcnn/train_v14_quadratic_rknn.py`
- `beagle/spectrum_to_rgb.py`

维护本文时，应明确标记“已验证实现”“迁移设计”和“历史实验”，避免把尚未完成的 RAW 校正链路描述为可直接部署功能。
