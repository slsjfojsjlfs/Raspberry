#!/usr/bin/env python3
"""Run the v14-r8 CPU spectral reconstruction pipeline on Raspberry Pi 5."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import time

import numpy as np

from spectral_reconstruction import (
    build_x41,
    load_manifest,
    load_weights,
    reconstruct_to_file,
    render_rgb,
    sha256_file,
)


ALLOWED_RESULT_ROOT = Path("/home/r/Raspberry/Result")


def resolve_path(value: str, base: Path) -> Path:
    path = Path(value).expanduser()
    return (path if path.is_absolute() else base / path).resolve()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default="/home/r/Raspberry/Algorithm/config.json",
        help="JSON configuration file",
    )
    args = parser.parse_args()

    config_path = Path(args.config).expanduser().resolve()
    with config_path.open("r", encoding="utf-8") as source:
        config = json.load(source)
    base = config_path.parent

    input_dir = resolve_path(config["input_dir"], base)
    manifest_path = resolve_path(config["manifest"], base)
    weights_path = resolve_path(config["weights"], base)
    cpp_weights_path = (
        resolve_path(config["cpp_weights"], base)
        if config.get("cpp_weights")
        else None
    )
    result_root = resolve_path(config.get("result_root", str(ALLOWED_RESULT_ROOT)), base)
    allowed = ALLOWED_RESULT_ROOT.resolve()
    if result_root != allowed and allowed not in result_root.parents:
        raise ValueError(f"result_root must remain under {allowed}: {result_root}")

    started = time.perf_counter()

    frames = load_manifest(manifest_path, input_dir)
    normalization = config["normalization"]
    if normalization.get("mode") == "dark_white":
        for entry in frames:
            entry["dark_path"] = resolve_path(entry["dark_file"], input_dir)
            entry["white_path"] = resolve_path(entry["white_file"], input_dir)

    weights = load_weights(weights_path, cpp_weights_path)
    chunk_size = int(config.get("chunk_size", 4096))

    run_name = datetime.now().strftime("run_%Y%m%d_%H%M%S")
    run_dir = result_root / run_name
    run_dir.mkdir(parents=True, exist_ok=False)

    stage_start = time.perf_counter()
    x41, height, width, frame_records = build_x41(
        frames,
        run_dir / "scene_x41.npy",
        normalization,
        config.get("raw"),
    )
    preprocess_seconds = time.perf_counter() - stage_start

    stage_start = time.perf_counter()
    spectrum = reconstruct_to_file(
        x41,
        run_dir / "spectrum_101.npy",
        weights,
        chunk_size,
    )
    inference_seconds = time.perf_counter() - stage_start
    np.save(run_dir / "wavelengths_nm.npy", weights.wavelengths_nm)

    rgb_scale = None
    rgb_seconds = None
    if weights.rgb_matrix is not None:
        stage_start = time.perf_counter()
        rgb_scale = render_rgb(
            spectrum,
            run_dir / "reconstructed_rgb.png",
            weights.rgb_matrix,
            height,
            width,
            chunk_size,
        )
        rgb_seconds = time.perf_counter() - stage_start

    report = {
        "status": "success",
        "algorithm": "v14-r8 CPU float32 quadratic regression",
        "created_at": datetime.now().astimezone().isoformat(),
        "input_dir": str(input_dir),
        "manifest": str(manifest_path),
        "manifest_sha256": sha256_file(manifest_path),
        "weights": str(weights_path),
        "weights_sha256": sha256_file(weights_path),
        "cpp_weights": str(cpp_weights_path) if cpp_weights_path else None,
        "cpp_weights_sha256": (
            sha256_file(cpp_weights_path) if cpp_weights_path else None
        ),
        "image_shape": [height, width],
        "x41_shape": [height * width, 41],
        "spectrum_shape": [height, width, 101],
        "spectrum_range": [float(spectrum.min()), float(spectrum.max())],
        "chunk_size": chunk_size,
        "normalization": normalization,
        "frames": frame_records,
        "rgb_generated": weights.rgb_matrix is not None,
        "rgb_percentile_scale": rgb_scale,
        "timing_seconds": {
            "preprocess": preprocess_seconds,
            "inference": inference_seconds,
            "rgb": rgb_seconds,
            "total": time.perf_counter() - started,
        },
    }
    with (run_dir / "report.json").open("w", encoding="utf-8") as target:
        json.dump(report, target, ensure_ascii=False, indent=2)
        target.write("\n")

    print(f"Completed: {run_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
