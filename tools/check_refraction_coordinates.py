#!/usr/bin/env python3
"""Inspect native transmitted-coordinate snapshots at one fixed camera.

These diagnostics measure local image folds and jumps, not complete optical
correctness. Wave phase can differ between runs. Final production images,
moving views and performance still require separate native checks.
"""
import argparse
import json
from pathlib import Path

import numpy as np


def inspect(directory, scene):
    """Reject stale attachments and measure the shallow-water coordinate field."""
    metadata = json.loads((directory / f"{scene}-runtime.json").read_text(encoding="utf-8"))
    layout = metadata["refraction_coordinate_probe"]
    width, height = layout["width"], layout["height"]
    field = np.fromfile(directory / f"{scene}-refraction.bin", dtype="<f4").reshape(height, width, 4)
    assert np.isfinite(field).all(), "Invalid coordinate snapshot"
    coverage = field[..., 3] > 0.5
    assert int(coverage.sum()) == int(metadata["water_surface_normals"]["pixels"]), \
        "Snapshot coverage differs from the native water attachment"
    offset = np.linalg.norm(field[..., :2], axis=-1)
    assert np.count_nonzero(coverage & (offset > 0.1)) > coverage.sum() * 0.01, \
        "Snapshot has no meaningful refraction; check the executable output binding"
    y, x = np.mgrid[:height, :width]
    coordinates = field[..., :2] + np.stack((x, y), axis=-1)
    dx = coordinates[:-1, 1:] - coordinates[:-1, :-1]
    dy = coordinates[1:, :-1] - coordinates[:-1, :-1]
    shallow = coverage[:-1, :-1] & coverage[:-1, 1:] & coverage[1:, :-1] & (field[:-1, :-1, 2] < 5)
    determinant = dx[..., 0] * dy[..., 1] - dx[..., 1] * dy[..., 0]
    jump = np.maximum(np.linalg.norm(dx, axis=-1), np.linalg.norm(dy, axis=-1))
    assert shallow.sum() > 1000, "Insufficient shallow-water coverage"
    result = {
        "renderer": metadata["renderer"],
        "camera": metadata["camera"],
        "framebuffer": [width, height],
        "water_pixels": int(coverage.sum()),
        "shallow_neighbourhoods": int(shallow.sum()),
        "moved_pixels": int(np.count_nonzero(coverage & (offset > 0.1))),
        "folds": int(np.count_nonzero(shallow & (determinant <= 0))),
        "fold_fraction": float(np.mean(determinant[shallow] <= 0)),
        "jump_p99_pixels": float(np.quantile(jump[shallow], 0.99)),
        "jump_max_pixels": float(jump[shallow].max()),
        "offset_p95_pixels": float(np.quantile(offset[coverage], 0.95)),
    }
    return result


def main():
    """Compare matched native cameras without treating one frame as full acceptance."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--scene", default="water_user_shore")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline = inspect(args.baseline, args.scene)
    candidate = inspect(args.candidate, args.scene)
    assert baseline["renderer"] == candidate["renderer"], "Different native renderers"
    assert baseline["camera"] == candidate["camera"], "Different camera poses"
    assert baseline["framebuffer"] == candidate["framebuffer"], "Different framebuffers"
    assert candidate["fold_fraction"] < 0.001, "Shallow-water mapping still folds"
    assert candidate["jump_max_pixels"] < 4, "Shallow-water coordinate discontinuity remains"
    result = {
        "scope": "One native fixed-camera shallow-water snapshot; wave phases are not locked",
        "baseline": baseline,
        "candidate": candidate,
        "full_goal_accepted": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
