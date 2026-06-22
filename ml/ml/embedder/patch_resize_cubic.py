"""Patch dinov2_small.onnx: replace Resize 'cubic' with 'linear'.

onnxruntime-android 1.15.1 rejects 'cubic' on 4D tensors at runtime even when
outer scales are 1.0. The accuracy delta of bilinear positional-embedding
interpolation is negligible for embedding similarity.

Usage:
    uv run python -m ml.embedder.patch_resize_cubic
"""
from __future__ import annotations

from pathlib import Path

import onnx

DEFAULT_PATH = Path(__file__).resolve().parents[3] / "app" / "assets" / "models" / "dinov2_small.onnx"


def patch(path: Path) -> int:
    model = onnx.load(str(path))
    changed = 0
    for node in model.graph.node:
        if node.op_type != "Resize":
            continue
        for attr in node.attribute:
            if attr.name == "mode" and attr.s == b"cubic":
                attr.s = b"linear"
                changed += 1
    if changed:
        onnx.save(model, str(path))
    return changed


if __name__ == "__main__":
    n = patch(DEFAULT_PATH)
    print(f"Patched {n} Resize node(s) cubic -> linear in {DEFAULT_PATH}")
