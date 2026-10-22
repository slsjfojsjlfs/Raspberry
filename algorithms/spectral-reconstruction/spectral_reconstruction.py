"""CPU/NumPy implementation of the v14-r8 spectral reconstruction model."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct
from typing import Any, Iterable

import cv2
import numpy as np
from numpy.lib.format import open_memmap


CHANNEL_COUNT = 41
QUADRATIC_COUNT = CHANNEL_COUNT * (CHANNEL_COUNT + 1) // 2
SPECTRAL_COUNT = 101


@dataclass(frozen=True)
class Weights:
    pair_i: np.ndarray
    pair_j: np.ndarray
    linear: np.ndarray
    quadratic_right: np.ndarray
    quadratic_left: np.ndarray
    bias: np.ndarray
    rgb_matrix: np.ndarray | None
    wavelengths_nm: np.ndarray


def sha256_file(path: Path, block_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(block_size):
            digest.update(block)
    return digest.hexdigest()


def _first_key(container: Any, names: Iterable[str]) -> np.ndarray:
    for name in names:
        if name in container:
            return np.asarray(container[name])
    raise KeyError(f"Missing weight key; expected one of: {', '.join(names)}")


def load_cpp_weights(path: Path) -> Weights:
    """Load the exported V14R8B2 binary used by the original C++ program."""
    if not path.is_file():
        raise FileNotFoundError(f"C++ weight file not found: {path}")

    with path.open("rb") as source:
        magic = source.read(8)
        if magic != b"V14R8B2\0":
            raise ValueError(f"Unsupported C++ weight magic in {path}: {magic!r}")
        input_dim, output_dim, pair_count, rank = struct.unpack("<4I", source.read(16))
        if (input_dim, output_dim, pair_count, rank) != (
            CHANNEL_COUNT,
            SPECTRAL_COUNT,
            QUADRATIC_COUNT,
            8,
        ):
            raise ValueError(
                "Unexpected C++ weight dimensions: "
                f"{(input_dim, output_dim, pair_count, rank)}"
            )

        def read_array(dtype: str, count: int) -> np.ndarray:
            itemsize = np.dtype(dtype).itemsize
            payload = source.read(count * itemsize)
            if len(payload) != count * itemsize:
                raise ValueError(f"Truncated C++ weight file: {path}")
            return np.frombuffer(payload, dtype=dtype).copy()

        pair_i = read_array("<i4", pair_count).astype(np.int64)
        pair_j = read_array("<i4", pair_count).astype(np.int64)
        linear = read_array("<f4", input_dim * output_dim).reshape(
            input_dim, output_dim
        ).T
        right = read_array("<f4", pair_count * rank).reshape(pair_count, rank).T
        left = read_array("<f4", rank * output_dim).reshape(rank, output_dim).T
        bias = read_array("<f4", output_dim)
        rgb_matrix = read_array("<f4", output_dim * 3).reshape(output_dim, 3)
        if source.read(1):
            raise ValueError(f"Unexpected trailing bytes in C++ weight file: {path}")

    return Weights(
        pair_i=pair_i,
        pair_j=pair_j,
        linear=linear,
        quadratic_right=right,
        quadratic_left=left,
        bias=bias,
        rgb_matrix=rgb_matrix,
        wavelengths_nm=np.arange(400, 804, 4, dtype=np.float32),
    )


def load_weights(path: Path, cpp_path: Path | None = None) -> Weights:
    if not path.is_file():
        raise FileNotFoundError(
            f"Weight file not found: {path}. Copy the real v14-r8 NPZ weights "
            "from the training project; placeholder weights are not accepted."
        )

    with np.load(path, allow_pickle=False) as data:
        if "pair_i" in data and "pair_j" in data:
            pair_i = np.asarray(data["pair_i"], dtype=np.int64)
            pair_j = np.asarray(data["pair_j"], dtype=np.int64)
        else:
            pair_i, pair_j = np.triu_indices(CHANNEL_COUNT)

        linear = _first_key(data, ("linear_weight", "linear")).astype(np.float32)
        right = _first_key(data, ("quadratic_right", "q_right")).astype(np.float32)
        left = _first_key(data, ("quadratic_left", "q_left")).astype(np.float32)
        bias = np.asarray(data["bias"], dtype=np.float32)
        rgb_matrix = (
            np.asarray(data["rgb_matrix"], dtype=np.float32)
            if "rgb_matrix" in data
            else None
        )
        wavelengths = (
            np.asarray(data["wavelengths_nm"], dtype=np.float32)
            if "wavelengths_nm" in data
            else np.arange(400, 804, 4, dtype=np.float32)
        )

    expected_shapes = {
        "pair_i": (QUADRATIC_COUNT,),
        "pair_j": (QUADRATIC_COUNT,),
        "linear_weight": (SPECTRAL_COUNT, CHANNEL_COUNT),
        "quadratic_right": (8, QUADRATIC_COUNT),
        "quadratic_left": (SPECTRAL_COUNT, 8),
        "bias": (SPECTRAL_COUNT,),
        "wavelengths_nm": (SPECTRAL_COUNT,),
    }
    actual = {
        "pair_i": pair_i.shape,
        "pair_j": pair_j.shape,
        "linear_weight": linear.shape,
        "quadratic_right": right.shape,
        "quadratic_left": left.shape,
        "bias": bias.shape,
        "wavelengths_nm": wavelengths.shape,
    }
    for name, expected in expected_shapes.items():
        if actual[name] != expected:
            raise ValueError(f"{name} shape is {actual[name]}, expected {expected}")

    if rgb_matrix is not None and rgb_matrix.shape != (SPECTRAL_COUNT, 3):
        raise ValueError(
            f"rgb_matrix shape is {rgb_matrix.shape}, expected {(SPECTRAL_COUNT, 3)}"
        )
    if np.any(pair_i < 0) or np.any(pair_i >= CHANNEL_COUNT):
        raise ValueError("pair_i contains an out-of-range channel index")
    if np.any(pair_j < 0) or np.any(pair_j >= CHANNEL_COUNT):
        raise ValueError("pair_j contains an out-of-range channel index")

    weights = Weights(
        pair_i=pair_i,
        pair_j=pair_j,
        linear=linear,
        quadratic_right=right,
        quadratic_left=left,
        bias=bias,
        rgb_matrix=rgb_matrix,
        wavelengths_nm=wavelengths,
    )

    if cpp_path is None:
        return weights

    cpp = load_cpp_weights(cpp_path)
    comparisons = {
        "pair_i": (weights.pair_i, cpp.pair_i),
        "pair_j": (weights.pair_j, cpp.pair_j),
        "linear": (weights.linear, cpp.linear),
        "quadratic_right": (weights.quadratic_right, cpp.quadratic_right),
        "quadratic_left": (weights.quadratic_left, cpp.quadratic_left),
        "bias": (weights.bias, cpp.bias),
    }
    for name, (npz_value, cpp_value) in comparisons.items():
        if not np.array_equal(npz_value, cpp_value):
            difference = float(np.max(np.abs(npz_value - cpp_value)))
            raise ValueError(
                f"NPZ and C++ binary disagree for {name}; max difference={difference}"
            )

    return Weights(
        pair_i=weights.pair_i,
        pair_j=weights.pair_j,
        linear=weights.linear,
        quadratic_right=weights.quadratic_right,
        quadratic_left=weights.quadratic_left,
        bias=weights.bias,
        rgb_matrix=weights.rgb_matrix if weights.rgb_matrix is not None else cpp.rgb_matrix,
        wavelengths_nm=weights.wavelengths_nm,
    )


def load_manifest(path: Path, input_dir: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as source:
        manifest = json.load(source)

    if manifest.get("production_ready") is not True:
        raise ValueError(
            "Manifest is not approved for production. Replace the example bias "
            "values, verify the 41-channel order, then set production_ready to true."
        )

    frames = manifest.get("frames")
    if not isinstance(frames, list) or len(frames) != CHANNEL_COUNT:
        raise ValueError(f"Manifest must contain exactly {CHANNEL_COUNT} frames")

    by_index: dict[int, dict[str, Any]] = {}
    for entry in frames:
        if not isinstance(entry, dict):
            raise ValueError("Every manifest frame must be an object")
        index = entry.get("channel_index")
        if not isinstance(index, int) or not 0 <= index < CHANNEL_COUNT:
            raise ValueError(f"Invalid channel_index: {index!r}")
        if index in by_index:
            raise ValueError(f"Duplicate channel_index: {index}")
        if not isinstance(entry.get("bias"), (int, float)):
            raise ValueError(f"Channel {index} has no numeric bias value")
        filename = entry.get("file")
        if not isinstance(filename, str) or not filename:
            raise ValueError(f"Channel {index} has no file name")
        frame_path = (input_dir / filename).resolve()
        if input_dir.resolve() not in frame_path.parents:
            raise ValueError(f"Frame path escapes input directory: {filename}")
        if not frame_path.is_file():
            raise FileNotFoundError(f"Frame file not found: {frame_path}")
        normalized = dict(entry)
        normalized["path"] = frame_path
        by_index[index] = normalized

    expected_indices = set(range(CHANNEL_COUNT))
    if set(by_index) != expected_indices:
        raise ValueError("Manifest channel indices must be exactly 0 through 40")
    return [by_index[index] for index in range(CHANNEL_COUNT)]


def read_frame(path: Path, raw: dict[str, Any] | None = None) -> np.ndarray:
    suffix = path.suffix.lower()
    if suffix == ".npy":
        frame = np.load(path, mmap_mode="r", allow_pickle=False)
    elif suffix == ".raw":
        if raw is None:
            raise ValueError(f"RAW input requires raw width, height and dtype: {path}")
        width = int(raw["width"])
        height = int(raw["height"])
        dtype = np.dtype(raw.get("dtype", "<u2"))
        expected_bytes = width * height * dtype.itemsize
        if path.stat().st_size != expected_bytes:
            raise ValueError(
                f"{path} has {path.stat().st_size} bytes; expected {expected_bytes}"
            )
        frame = np.memmap(path, mode="r", dtype=dtype, shape=(height, width))
    else:
        frame = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
        if frame is None:
            raise ValueError(f"OpenCV could not read image: {path}")

    if frame.ndim != 2:
        raise ValueError(f"Frame must be single-channel 2D data: {path}, {frame.shape}")
    return frame


def build_x41(
    frames: list[dict[str, Any]],
    output_path: Path,
    normalization: dict[str, Any],
    raw: dict[str, Any] | None = None,
) -> tuple[np.memmap, int, int, list[dict[str, Any]]]:
    first = read_frame(frames[0]["path"], raw)
    height, width = first.shape
    x41 = open_memmap(
        output_path,
        mode="w+",
        dtype=np.float32,
        shape=(height * width, CHANNEL_COUNT),
    )
    mode = normalization.get("mode")
    records: list[dict[str, Any]] = []

    for index, entry in enumerate(frames):
        frame = read_frame(entry["path"], raw)
        if frame.shape != (height, width):
            raise ValueError(
                f"Channel {index} shape is {frame.shape}, expected {(height, width)}"
            )
        values = np.asarray(frame, dtype=np.float32)

        if mode == "scale":
            offset = float(normalization.get("offset", 0.0))
            scale = float(normalization["scale"])
            if not np.isfinite(scale) or abs(scale) < 1e-12:
                raise ValueError("normalization.scale must be finite and non-zero")
            values = (values - offset) / scale
        elif mode == "dark_white":
            dark_name = entry.get("dark_file")
            white_name = entry.get("white_file")
            if not dark_name or not white_name:
                raise ValueError(
                    f"Channel {index} requires dark_file and white_file"
                )
            dark = np.asarray(read_frame(entry["dark_path"], raw), dtype=np.float32)
            white = np.asarray(read_frame(entry["white_path"], raw), dtype=np.float32)
            if dark.shape != frame.shape or white.shape != frame.shape:
                raise ValueError(f"Calibration shape mismatch for channel {index}")
            epsilon = float(normalization.get("epsilon", 1e-6))
            values = (values - dark) / (white - dark + epsilon)
        else:
            raise ValueError("normalization.mode must be 'scale' or 'dark_white'")

        if not np.all(np.isfinite(values)):
            raise ValueError(f"Channel {index} produced NaN or Inf values")
        if normalization.get("clip", True):
            values = np.clip(values, 0.0, 1.0)
        x41[:, index] = values.reshape(-1)
        records.append(
            {
                "channel_index": index,
                "bias": entry["bias"],
                "file": entry["path"].name,
                "sha256": sha256_file(entry["path"]),
            }
        )

    x41.flush()
    return x41, height, width, records


def reconstruct_chunk(x: np.ndarray, weights: Weights) -> np.ndarray:
    part = np.ascontiguousarray(x, dtype=np.float32)
    quadratic = part[:, weights.pair_i] * part[:, weights.pair_j]
    result = part @ weights.linear.T
    result += (quadratic @ weights.quadratic_right.T) @ weights.quadratic_left.T
    result += weights.bias
    return np.clip(result, 0.0, 1.0)


def reconstruct_to_file(
    x41: np.ndarray,
    output_path: Path,
    weights: Weights,
    chunk_size: int,
) -> np.memmap:
    if x41.ndim != 2 or x41.shape[1] != CHANNEL_COUNT:
        raise ValueError(f"x41 shape is {x41.shape}, expected (N, {CHANNEL_COUNT})")
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")

    spectrum = open_memmap(
        output_path,
        mode="w+",
        dtype=np.float32,
        shape=(x41.shape[0], SPECTRAL_COUNT),
    )
    for start in range(0, x41.shape[0], chunk_size):
        stop = min(start + chunk_size, x41.shape[0])
        spectrum[start:stop] = reconstruct_chunk(x41[start:stop], weights)
    spectrum.flush()
    return spectrum


def render_rgb(
    spectrum: np.ndarray,
    output_path: Path,
    rgb_matrix: np.ndarray,
    height: int,
    width: int,
    chunk_size: int,
) -> float:
    rgb_linear = np.empty((spectrum.shape[0], 3), dtype=np.float32)
    for start in range(0, spectrum.shape[0], chunk_size):
        stop = min(start + chunk_size, spectrum.shape[0])
        rgb_linear[start:stop] = spectrum[start:stop] @ rgb_matrix

    scale = float(np.percentile(rgb_linear, 99.5))
    if scale > 1e-12:
        rgb_linear /= scale
    rgb_linear = np.clip(rgb_linear, 0.0, 1.0)
    rgb = np.where(
        rgb_linear <= 0.0031308,
        12.92 * rgb_linear,
        1.055 * np.power(rgb_linear, 1.0 / 2.4) - 0.055,
    )
    rgb8 = np.round(np.clip(rgb, 0.0, 1.0) * 255.0).astype(np.uint8)
    bgr8 = cv2.cvtColor(rgb8.reshape(height, width, 3), cv2.COLOR_RGB2BGR)
    if not cv2.imwrite(str(output_path), bgr8):
        raise RuntimeError(f"Failed to write RGB image: {output_path}")
    return scale
