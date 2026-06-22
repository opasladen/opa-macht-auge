"""Dynamische INT8-Quantisierung des DINOv2-ONNX-Models.

Dynamic Quantization quantisiert Gewichte zu INT8 (Activations bleiben fp32).
Reduziert Modellgroesse ~4x bei vernachlaessigbarem Genauigkeitsverlust.

Aufruf:
    uv run --group export python -m ml.embedder.quantize_onnx
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
import typer
from onnxruntime.quantization import QuantType, quantize_dynamic
from rich.console import Console

DEFAULT_IN = Path(__file__).resolve().parents[3] / "app" / "assets" / "models" / "dinov2_small.onnx"
DEFAULT_OUT = DEFAULT_IN.with_name("dinov2_small_int8.onnx")

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


@app.command()
def main(
    src: Path = typer.Option(DEFAULT_IN, "--src"),
    dst: Path = typer.Option(DEFAULT_OUT, "--dst"),
) -> None:
    if not src.exists():
        raise typer.BadParameter(f"{src} nicht gefunden - erst export_onnx laufen lassen.")

    console.print(f"[bold]Quantisiere {src.name} -> {dst.name}[/bold]")
    quantize_dynamic(
        model_input=str(src),
        model_output=str(dst),
        weight_type=QuantType.QInt8,
    )

    src_mb = src.stat().st_size / (1024 * 1024)
    dst_mb = dst.stat().st_size / (1024 * 1024)
    console.print(f"fp32: {src_mb:.1f} MB  ->  int8: {dst_mb:.1f} MB  ({dst_mb / src_mb * 100:.0f}%)")

    # Genauigkeit gegen fp32 vergleichen
    dummy = torch.randn(2, 3, 224, 224, dtype=torch.float32).numpy()
    sess_fp32 = ort.InferenceSession(str(src), providers=["CPUExecutionProvider"])
    sess_int8 = ort.InferenceSession(str(dst), providers=["CPUExecutionProvider"])
    out_fp32 = sess_fp32.run(None, {"pixel_values": dummy})[0]
    out_int8 = sess_int8.run(None, {"pixel_values": dummy})[0]

    cos_sim = np.sum(out_fp32 * out_int8, axis=-1) / (
        np.linalg.norm(out_fp32, axis=-1) * np.linalg.norm(out_int8, axis=-1)
    )
    max_diff = float(np.abs(out_fp32 - out_int8).max())
    console.print(f"max-abs-diff fp32 vs int8: {max_diff:.3e}")
    console.print(f"cosine-similarity pro Sample: {cos_sim.tolist()}")
    if cos_sim.min() < 0.95:
        console.print(f"[red]WARNUNG: Cosine-Similarity {cos_sim.min():.4f} < 0.95[/red]")


if __name__ == "__main__":
    app()
