"""YOLOv8n Training-Skript fuer Karten-Bounding-Boxes.

Erwartet ein DVC-gestaktes Dataset in `datasets/cards_detect/` im YOLO-Format:
    datasets/cards_detect/
        images/{train,val}/*.jpg
        labels/{train,val}/*.txt
        data.yaml

Verwendung:
    uv run --group train python -m ml.detector.train \
        --data datasets/cards_detect/data.yaml --epochs 80 --imgsz 640
"""
from __future__ import annotations

from pathlib import Path

import typer

app = typer.Typer(add_completion=False)


@app.command()
def main(
    data: Path = typer.Option(..., help="data.yaml im YOLO-Format"),
    epochs: int = 80,
    imgsz: int = 640,
    batch: int = 32,
    project: Path = Path("runs/detector"),
    name: str = "yolov8n_cards",
) -> None:
    # Lazy-Import: torch/ultralytics liegen in der `train`-Gruppe.
    from ultralytics import YOLO

    model = YOLO("yolov8n.pt")
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

    # Export fuer Mobile: ONNX + TFLite (INT8 quantisiert).
    weights = project / name / "weights" / "best.pt"
    onnx_model = YOLO(str(weights))
    onnx_model.export(format="onnx", imgsz=imgsz, opset=12, simplify=True)
    onnx_model.export(format="tflite", imgsz=imgsz, int8=True, data=str(data))


if __name__ == "__main__":
    app()
