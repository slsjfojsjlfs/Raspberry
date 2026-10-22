#!/usr/bin/env python3
"""Validate the migrated production weights with the original x41 sample."""

from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
import time

import cv2
import numpy as np

from spectral_reconstruction import load_weights, reconstruct_chunk, sha256_file


ROOT = Path("/home/r/Raspberry")
NPZ_PATH = ROOT / "Algorithm/weights/spectral_recon_v14_quadratic_rank8_weights.npz"
BIN_PATH = ROOT / "Algorithm/weights/spectral_recon_v14_quadratic_rank8_cpp.bin"
INPUT_PATH = ROOT / "Algorithm/reference/colorchecker_x41.npy"
RESULT_DIR = ROOT / "Result/reference_validation"


def main() -> int:
    weights = load_weights(NPZ_PATH, BIN_PATH)
    x41 = np.asarray(np.load(INPUT_PATH, allow_pickle=False), dtype=np.float32)
    if x41.ndim != 2 or x41.shape[1] != 41:
        raise ValueError(f"Expected x41 shape (N, 41), got {x41.shape}")
    if not np.all(np.isfinite(x41)):
        raise ValueError("Reference input contains NaN or Inf")

    started = time.perf_counter()
    spectrum = reconstruct_chunk(x41, weights)
    elapsed = time.perf_counter() - started
    if spectrum.shape != (x41.shape[0], 101) or not np.all(np.isfinite(spectrum)):
        raise ValueError(f"Invalid production output: {spectrum.shape}")

    RESULT_DIR.mkdir(parents=True, exist_ok=True)
    spectrum_path = RESULT_DIR / "colorchecker_spectrum_101.npy"
    np.save(spectrum_path, spectrum)
    np.save(RESULT_DIR / "wavelengths_nm.npy", weights.wavelengths_nm)

    preview_generated = False
    if x41.shape[0] == 24 and weights.rgb_matrix is not None:
        rgb_linear = spectrum @ weights.rgb_matrix
        scale = float(np.percentile(rgb_linear, 99.5))
        if scale > 1e-12:
            rgb_linear /= scale
        rgb_linear = np.clip(rgb_linear, 0.0, 1.0)
        rgb = np.where(
            rgb_linear <= 0.0031308,
            12.92 * rgb_linear,
            1.055 * np.power(rgb_linear, 1.0 / 2.4) - 0.055,
        )
        patches = np.round(rgb.reshape(4, 6, 3) * 255.0).astype(np.uint8)
        preview = cv2.resize(patches[:, :, ::-1], (600, 400), interpolation=cv2.INTER_NEAREST)
        preview_generated = bool(cv2.imwrite(str(RESULT_DIR / "colorchecker_rgb.png"), preview))

    report = {
        "status": "passed",
        "scope": "production weights execution and NPZ/BIN exact-consistency check",
        "created_at": datetime.now().astimezone().isoformat(),
        "input": str(INPUT_PATH),
        "input_sha256": sha256_file(INPUT_PATH),
        "input_shape": list(x41.shape),
        "npz_sha256": sha256_file(NPZ_PATH),
        "bin_sha256": sha256_file(BIN_PATH),
        "output": str(spectrum_path),
        "output_sha256": sha256_file(spectrum_path),
        "output_shape": list(spectrum.shape),
        "output_range": [float(spectrum.min()), float(spectrum.max())],
        "output_mean": float(spectrum.mean()),
        "elapsed_seconds": elapsed,
        "rgb_preview_generated": preview_generated,
        "accuracy_note": "No ground-truth spectrum is bundled; this is an execution/integrity check, not an accuracy evaluation.",
    }
    with (RESULT_DIR / "report.json").open("w", encoding="utf-8") as target:
        json.dump(report, target, indent=2, ensure_ascii=False)
        target.write("\n")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
