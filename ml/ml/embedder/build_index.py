"""Indexbau: laedt alle Karten-Bilder, berechnet DINOv2-Embeddings und schreibt sie in pgvector.

Pipeline:
    1. Karten ohne Embedding (oder alle bei --rebuild) aus DB selektieren
    2. image_url_small parallel via httpx.AsyncClient streamen
    3. DINOv2-small (Output 384-dim, matched ml_embedding_dim) auf CPU laufen lassen
    4. L2-normalisierte Vektoren bulk-upsert in card_embeddings (HNSW + cosine_ops)

Aufruf:
    uv run python -m ml.embedder.build_index
    uv run python -m ml.embedder.build_index --rebuild --batch-size 16
"""
from __future__ import annotations

import asyncio
import io
import sys
import uuid
from collections.abc import Iterable

import httpx
import numpy as np
import torch
import torch.nn.functional as F
import typer
from PIL import Image
from rich.console import Console
from rich.progress import (
    BarColumn,
    Progress,
    TextColumn,
    TimeElapsedColumn,
    TimeRemainingColumn,
)
from sqlalchemy import create_engine, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session
from transformers import AutoImageProcessor, AutoModel

from ml.config import get_settings

try:
    from app.infra.models import Card, CardEmbedding  # type: ignore[import-not-found]
except ImportError:
    sys.stderr.write(
        "Backend-Modelle nicht importierbar. Setze PYTHONPATH:\n"
        '  $env:PYTHONPATH = "../backend"\n'
    )
    raise

DEFAULT_MODEL = "facebook/dinov2-small"  # 384-D CLS-Token, ~22M Params

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


def _load_model(model_name: str) -> tuple[AutoImageProcessor, AutoModel]:
    console.print(f"[bold]Lade Modell {model_name} (CPU)...[/bold]")
    processor = AutoImageProcessor.from_pretrained(model_name)
    model = AutoModel.from_pretrained(model_name)
    model.eval()
    out_dim = int(model.config.hidden_size)
    settings = get_settings()
    if out_dim != settings.ml_embedding_dim:
        raise RuntimeError(
            f"Modell-Output-Dim {out_dim} passt nicht zu ml_embedding_dim={settings.ml_embedding_dim}."
        )
    return processor, model


async def _fetch_image(client: httpx.AsyncClient, url: str) -> Image.Image | None:
    try:
        resp = await client.get(url)
        resp.raise_for_status()
        return Image.open(io.BytesIO(resp.content)).convert("RGB")
    except Exception as exc:  # noqa: BLE001
        console.print(f"[red]Bild-Fehler {url}: {exc}[/red]")
        return None


async def _fetch_batch(
    client: httpx.AsyncClient, urls: Iterable[str]
) -> list[Image.Image | None]:
    return await asyncio.gather(*(_fetch_image(client, u) for u in urls))


@torch.inference_mode()
def _embed(
    processor: AutoImageProcessor, model: AutoModel, images: list[Image.Image]
) -> np.ndarray:
    inputs = processor(images=images, return_tensors="pt")
    outputs = model(**inputs)
    # DINOv2: last_hidden_state hat Shape (B, N+1, D); CLS-Token = Index 0.
    cls = outputs.last_hidden_state[:, 0]  # (B, 384)
    cls = F.normalize(cls, p=2, dim=-1)
    return cls.cpu().numpy().astype(np.float32)


@app.command()
def main(
    model_name: str = typer.Option(DEFAULT_MODEL, "--model"),
    model_version: str = typer.Option("dinov2-s-2026.06", "--model-version"),
    batch_size: int = typer.Option(16, "--batch-size"),
    rebuild: bool = typer.Option(
        False, "--rebuild", help="Auch bereits vorhandene Embeddings neu berechnen"
    ),
    limit: int = typer.Option(0, "--limit", help="0 = alle"),
    concurrency: int = typer.Option(
        8, "--concurrency", help="Parallele HTTP-Downloads pro Batch"
    ),
) -> None:
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)
    processor, model = _load_model(model_name)

    with Session(engine) as session:
        stmt = select(Card.id, Card.image_url_small).where(Card.image_url_small.is_not(None))
        if not rebuild:
            stmt = stmt.outerjoin(
                CardEmbedding, CardEmbedding.card_id == Card.id
            ).where(CardEmbedding.id.is_(None))
        if limit:
            stmt = stmt.limit(limit)
        rows = session.execute(stmt).all()
        total = len(rows)
        console.print(f"[bold]{total}[/bold] Karten zu embedden (model_version={model_version}).")
        if total == 0:
            return

        limits = httpx.Limits(max_connections=concurrency, max_keepalive_connections=concurrency)

        async def run() -> int:
            written = 0
            async with httpx.AsyncClient(timeout=30.0, limits=limits) as http:
                with Progress(
                    TextColumn("{task.description}"),
                    BarColumn(),
                    TextColumn("{task.completed}/{task.total}"),
                    TimeElapsedColumn(),
                    TimeRemainingColumn(),
                    console=console,
                ) as bar:
                    task = bar.add_task("Embedding", total=total)
                    for i in range(0, total, batch_size):
                        chunk = rows[i : i + batch_size]
                        urls = [r.image_url_small for r in chunk]
                        images = await _fetch_batch(http, urls)
                        valid = [
                            (r.id, img)
                            for r, img in zip(chunk, images, strict=True)
                            if img is not None
                        ]
                        if valid:
                            ids = [vid for vid, _ in valid]
                            imgs = [img for _, img in valid]
                            vectors = _embed(processor, model, imgs)
                            payload = [
                                {
                                    "id": uuid.uuid4(),
                                    "card_id": cid,
                                    "model_version": model_version,
                                    "vector": vec.tolist(),
                                }
                                for cid, vec in zip(ids, vectors, strict=True)
                            ]
                            stmt_ins = insert(CardEmbedding).values(payload)
                            stmt_ins = stmt_ins.on_conflict_do_update(
                                constraint="uq_card_embeddings_card_id",
                                set_={
                                    "vector": stmt_ins.excluded.vector,
                                    "model_version": stmt_ins.excluded.model_version,
                                },
                            )
                            session.execute(stmt_ins)
                            session.commit()
                            written += len(valid)
                        bar.update(task, advance=len(chunk))
            return written

        written = asyncio.run(run())
        console.print(f"[green]Fertig. Geschriebene Embeddings: {written}/{total}[/green]")


if __name__ == "__main__":
    app()
