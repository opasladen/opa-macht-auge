"""Verifiziert ONNX-Embedder gegen pgvector: laedt ein TCGdex-Bild,
berechnet Embedding via onnxruntime, queriet /identify."""
from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import httpx
import numpy as np
import onnxruntime as ort
import typer
from PIL import Image

DEFAULT_ONNX = Path(__file__).resolve().parents[3] / "app" / "assets" / "models" / "dinov2_small.onnx"

# DE Glurak-ex sv03.5 Alt-Art 199
DEFAULT_URL = "https://assets.tcgdex.net/de/sv/sv03.5/199/low.webp"

app = typer.Typer(add_completion=False, no_args_is_help=False)


def preprocess(img: Image.Image, cfg: dict) -> np.ndarray:
    img = img.convert("RGB")
    if cfg.get("do_resize", True):
        # Resize so dass die kuerzere Seite = resize_shortest_edge ist (aspect ratio preserved)
        target = cfg["resize_shortest_edge"]
        w, h = img.size
        scale = target / min(w, h)
        new_w, new_h = int(round(w * scale)), int(round(h * scale))
        img = img.resize((new_w, new_h), Image.BICUBIC)
    if cfg.get("do_center_crop", True):
        crop_h, crop_w = cfg["crop_height"], cfg["crop_width"]
        w, h = img.size
        left = (w - crop_w) // 2
        top = (h - crop_h) // 2
        img = img.crop((left, top, left + crop_w, top + crop_h))
    arr = np.asarray(img, dtype=np.float32) * cfg["rescale_factor"]
    mean = np.asarray(cfg["image_mean"], dtype=np.float32)
    std = np.asarray(cfg["image_std"], dtype=np.float32)
    arr = (arr - mean) / std
    arr = arr.transpose(2, 0, 1)[None, :, :, :]  # NCHW
    return arr.astype(np.float32)


def main(
    onnx_path: Path = typer.Option(DEFAULT_ONNX, "--onnx"),
    url: str = typer.Option(DEFAULT_URL, "--url"),
) -> int:
    cfg_path = onnx_path.with_suffix(".preprocess.json")
    if not cfg_path.exists():
        # int8-Variante teilt sich Sidecar mit fp32-Variante
        cfg_path = onnx_path.with_name("dinov2_small.preprocess.json")
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    size_mb = onnx_path.stat().st_size / (1024 * 1024)
    print(f"Modell: {onnx_path.name} ({size_mb:.1f} MB)")
    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])

    img_bytes = httpx.get(url, timeout=30).content
    img = Image.open(io.BytesIO(img_bytes))
    print(f"Bild: {url}  (Original {img.size})")
    pixel_values = preprocess(img, cfg)
    emb = sess.run(None, {"pixel_values": pixel_values})[0][0]
    print(f"Embedding L2-Norm: {float(np.linalg.norm(emb)):.4f}")

    payload = {
        "embedding": emb.tolist(),
        "top_k": 3,
        "model_version": "dinov2-s-2026.06-onnx",
    }
    r = httpx.post("http://127.0.0.1:8000/api/v1/identify", json=payload, timeout=30)
    r.raise_for_status()
    data = r.json()
    print("Top-3 matches:")
    for m in data["matches"]:
        print(
            f"  - {m['name']:30s} {m['language']} {m['set_code']:10s} "
            f"#{m['number']}  sim={m['similarity']}"
        )
    return 0


if __name__ == "__main__":
    app.command()(main)
    app()
