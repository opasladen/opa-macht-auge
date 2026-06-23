"""YOLO11n OBB Training-Skript fuer Karten-Detection.

Erwartet ein YOLO-OBB-Dataset (siehe ml.detector.synth_dataset):
    datasets/cards_obb/
        images/{train,val}/*.jpg
        labels/{train,val}/*.txt  # cls x1 y1 x2 y2 x3 y3 x4 y4 (normalisiert)
        data.yaml

Verwendung:
    $env:PYTHONPATH = "..\\backend"
    uv run --group train python -m ml.detector.train \\
        --data datasets/cards_obb/data.yaml --epochs 80 --imgsz 1024

Inspiriert von 1vcian/Pokemon-TCGP-Card-Scanner (synthetisches Dataset +
YOLO-OBB), angepasst auf unsere DB-Backed-Card-Sources.
"""
from __future__ import annotations

from pathlib import Path

import typer

app = typer.Typer(add_completion=False)


@app.command()
def main(
    data: Path = typer.Option(..., help="data.yaml im YOLO-OBB-Format"),
    weights: str = typer.Option(
        "yolo11n-obb.pt",
        help="Pretrained-Weights (yolo11n-obb.pt = 2.7M Params, Mobile-tauglich)",
    ),
    epochs: int = 80,
    imgsz: int = 1024,
    batch: int = 16,
    project: Path = Path("runs/detector"),
    name: str = "yolo11n_obb_cards",
    export_onnx: bool = True,
    export_tflite: bool = False,
) -> None:
    # Lazy-Import: torch/ultralytics liegen in der `train`-Gruppe.
    from ultralytics import YOLO

    model = YOLO(weights)
    model.train(
        data=str(data),
        epochs=epochs,
        imgsz=imgsz,
        batch=batch,
        project=str(project),
        name=name,
        patience=15,
        cos_lr=True,
        amp=True,
    )

    # Export fuer Mobile/Web
    best = project / name / "weights" / "best.pt"
    if export_onnx:
        YOLO(str(best)).export(format="onnx", imgsz=imgsz, opset=12, simplify=True)
    if export_tflite:
        YOLO(str(best)).export(
            format="tflite", imgsz=imgsz, int8=True, data=str(data)
        )


if __name__ == "__main__":
    app()
