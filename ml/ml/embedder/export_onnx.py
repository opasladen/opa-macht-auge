"""DINOv2-small Export zu ONNX fuer den Mobile-Client.

Output:
    app/assets/models/dinov2_small.onnx                (~88 MB, fp32)
    app/assets/models/dinov2_small.preprocess.json     (mean/std/size aus AutoImageProcessor)

Pipeline:
    1. AutoImageProcessor + AutoModel laden (gleicher Weg wie build_index.py).
    2. Wrapper-Modul packt L2-Normalisierung in den Forward, damit der Client
       genau den 384-D-Vector erhaelt der in pgvector liegt.
    3. torch.onnx.export mit opset 17, dynamic batch axis.
    4. Verify: onnxruntime vs PyTorch auf Dummy-Input, max-abs-Diff < 1e-4.

Aufruf:
    uv run --group export python -m ml.embedder.export_onnx
    uv run --group export python -m ml.embedder.export_onnx --out custom/path.onnx
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
import typer
from rich.console import Console
from transformers import AutoImageProcessor, AutoModel

DEFAULT_MODEL = "facebook/dinov2-small"
DEFAULT_OUT = Path(__file__).resolve().parents[3] / "app" / "assets" / "models" / "dinov2_small.onnx"

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


class DinoV2Embedder(torch.nn.Module):
    """Wrapper: pixel_values -> L2-normalisiertes 384-D-Embedding."""

    def __init__(self, backbone: AutoModel) -> None:
        super().__init__()
        self.backbone = backbone

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        out = self.backbone(pixel_values=pixel_values)
        cls = out.last_hidden_state[:, 0]
        return F.normalize(cls, p=2, dim=-1)


def _processor_config(processor: AutoImageProcessor) -> dict:
    raw_size = getattr(processor, "size", None) or {}
    raw_crop = getattr(processor, "crop_size", None) or {}
    try:
        size = dict(raw_size)
    except (TypeError, ValueError):
        size = {"shortest_edge": int(raw_size)}
    try:
        crop = dict(raw_crop)
    except (TypeError, ValueError):
        crop = {"height": int(raw_crop), "width": int(raw_crop)}
    shortest_edge = size.get("shortest_edge") or crop.get("height") or 224
    crop_h = crop.get("height") or size.get("height") or shortest_edge
    crop_w = crop.get("width") or size.get("width") or shortest_edge
    return {
        "image_mean": list(processor.image_mean),
        "image_std": list(processor.image_std),
        "resize_shortest_edge": int(shortest_edge),
        "crop_height": int(crop_h),
        "crop_width": int(crop_w),
        "rescale_factor": float(getattr(processor, "rescale_factor", 1 / 255)),
        "resample": "bicubic",
        "do_center_crop": bool(getattr(processor, "do_center_crop", True)),
        "do_resize": bool(getattr(processor, "do_resize", True)),
    }


@app.command()
def main(
    model_name: str = typer.Option(DEFAULT_MODEL, "--model"),
    out: Path = typer.Option(DEFAULT_OUT, "--out"),
    opset: int = typer.Option(17, "--opset"),
) -> None:
    console.print(f"[bold]Lade {model_name} (CPU)[/bold]")
    processor = AutoImageProcessor.from_pretrained(model_name)
    backbone = AutoModel.from_pretrained(model_name)
    backbone.eval()

    wrapper = DinoV2Embedder(backbone).eval()
    cfg = _processor_config(processor)
    h, w = cfg["crop_height"], cfg["crop_width"]
    dummy = torch.randn(1, 3, h, w, dtype=torch.float32)

    with torch.inference_mode():
        torch_out = wrapper(dummy).numpy()

    out.parent.mkdir(parents=True, exist_ok=True)
    console.print(f"[bold]Exportiere ONNX nach {out} (opset={opset})[/bold]")
    torch.onnx.export(
        wrapper,
        (dummy,),
        str(out),
        input_names=["pixel_values"],
        output_names=["embedding"],
        dynamic_axes={"pixel_values": {0: "batch"}, "embedding": {0: "batch"}},
        opset_version=opset,
        do_constant_folding=True,
        dynamo=False,
    )

    sidecar = out.with_suffix(".preprocess.json")
    sidecar.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    console.print(f"[bold]Preprocessing-Config -> {sidecar}[/bold]")

    # Verify mit onnxruntime
    import onnxruntime as ort  # noqa: PLC0415 -- optional dependency

    sess = ort.InferenceSession(str(out), providers=["CPUExecutionProvider"])
    ort_out = sess.run(None, {"pixel_values": dummy.numpy()})[0]
    diff = float(np.abs(torch_out - ort_out).max())
    console.print(f"max-abs-diff PyTorch vs ONNX: {diff:.3e}")
    if diff > 1e-3:
        raise RuntimeError(f"ONNX-Output weicht zu stark ab: {diff}")

    # Batch-Test (dyn axis)
    dummy_batch = torch.randn(4, 3, h, w, dtype=torch.float32)
    ort_batch = sess.run(None, {"pixel_values": dummy_batch.numpy()})[0]
    console.print(f"Batch-Shape: {ort_batch.shape} (erwartet (4, {backbone.config.hidden_size}))")

    size_mb = out.stat().st_size / (1024 * 1024)
    console.print(f"[green]Fertig. ONNX-Groesse {size_mb:.1f} MB[/green]")


if __name__ == "__main__":
    app()
