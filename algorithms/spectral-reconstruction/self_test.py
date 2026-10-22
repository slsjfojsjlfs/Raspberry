#!/usr/bin/env python3
"""Deterministic numerical self-test; does not use production weights."""

from pathlib import Path
import json

import numpy as np

from spectral_reconstruction import (
    CHANNEL_COUNT,
    QUADRATIC_COUNT,
    SPECTRAL_COUNT,
    Weights,
    reconstruct_chunk,
)


def main() -> int:
    rng = np.random.default_rng(568)
    pair_i, pair_j = np.triu_indices(CHANNEL_COUNT)
    weights = Weights(
        pair_i=pair_i,
        pair_j=pair_j,
        linear=rng.normal(0, 0.01, (SPECTRAL_COUNT, CHANNEL_COUNT)).astype(np.float32),
        quadratic_right=rng.normal(0, 0.005, (8, QUADRATIC_COUNT)).astype(np.float32),
        quadratic_left=rng.normal(0, 0.005, (SPECTRAL_COUNT, 8)).astype(np.float32),
        bias=np.full(SPECTRAL_COUNT, 0.5, dtype=np.float32),
        rgb_matrix=None,
        wavelengths_nm=np.arange(400, 804, 4, dtype=np.float32),
    )
    x = rng.random((23, CHANNEL_COUNT), dtype=np.float32)
    actual = reconstruct_chunk(x, weights)
    quadratic = x[:, pair_i] * x[:, pair_j]
    expected = np.clip(
        x @ weights.linear.T
        + (quadratic @ weights.quadratic_right.T) @ weights.quadratic_left.T
        + weights.bias,
        0.0,
        1.0,
    )
    difference = np.abs(actual - expected)
    if actual.shape != (23, SPECTRAL_COUNT):
        raise AssertionError(f"Unexpected output shape: {actual.shape}")
    if not np.all(np.isfinite(actual)):
        raise AssertionError("Output contains NaN or Inf")
    if float(difference.max()) > 1e-6:
        raise AssertionError(f"Numerical mismatch: {difference.max()}")

    result_dir = Path("/home/r/Raspberry/Result/selftest")
    result_dir.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "passed",
        "seed": 568,
        "input_shape": list(x.shape),
        "output_shape": list(actual.shape),
        "mae": float(difference.mean()),
        "max_abs_error": float(difference.max()),
        "note": "Synthetic weights only; this does not validate production accuracy.",
    }
    with (result_dir / "report.json").open("w", encoding="utf-8") as target:
        json.dump(report, target, ensure_ascii=False, indent=2)
        target.write("\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
