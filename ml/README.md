# ml - Computer-Vision Pipeline

Trainings- und Inferenz-Tools fuer Detektor und Embedder von "Opa macht Auge".

## Module

| Modul              | Zweck                                                                  |
|--------------------|------------------------------------------------------------------------|
| `ml.bootstrap`     | Daten-Ingestion (pokemontcg.io -> Postgres + Rohbilder)                |
| `ml.detector`      | YOLOv8-Training fuer Multi-Karten-Erkennung + TFLite-Export            |
| `ml.embedder`      | Backbone-Inferenz (DINOv2-distilled) + HNSW-Indexbau in pgvector       |
| `ml.ocr_postproc`  | Set-Symbol-Klassifikator + Edition-Stempel-ROI                         |

## Setup

```powershell
uv sync                       # nur Inferenz-Deps
uv sync --group train         # mit Torch/Ultralytics fuer Training
```

## Pokemon-Master-Index initial befuellen

```powershell
# Voraussetzung: docker compose up -d (Postgres laeuft)
# Voraussetzung: Backend-Migrationen wurden ausgefuehrt
uv run python -m ml.bootstrap.pokemontcg --limit 250
```

## DVC

```powershell
uv run dvc init
uv run dvc remote add -d origin s3://opa-macht-auge-dvc
```
