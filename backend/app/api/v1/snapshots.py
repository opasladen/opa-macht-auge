"""Embedding-Snapshot fuer On-Device Lookup.

Liefert alle Karten-Embeddings eines Game-Slugs als kompaktes Binaer-Blob.
Der Flutter-Client laedt diesen Blob einmalig (~16 MB fuer 40k Karten,
INT8-quantisiert mit per-Vektor-Skala), speichert ihn lokal und macht den
TopK-Match danach komplett on-device. Ein ETag erlaubt Delta-Updates ueber
``If-None-Match`` (304 ohne Body, wenn der Client schon den aktuellen Snapshot
hat).

Binaer-Format (Little-Endian, alle Offsets Byte-aligned auf 4):

    Header (84 bytes total):
        magic        4 bytes   b"OMAE"
        version      u32       = 1
        count        u32       N
        dim          u32       D
        flags        u32       Bitfeld; aktuell nur 0x01 = INT8+per-Vektor-Skala
        model_ver    32 bytes  ASCII null-padded
        game_slug    32 bytes  ASCII null-padded
    Body:
        card_ids     N * 16 bytes  (UUID raw)
        scales       N * f32       (per-Vektor max_abs / 127)
        vectors      N * D * i8    (q[i,j] = round(v[i,j] / scales[i]))

Decoded Embedding: ``v[i,j] = q[i,j] * scales[i]``. Da alle Index-Vektoren
L2-normalisiert sind, ist ``max_abs(v) <= 1`` und der relative Quantisierungs-
fehler liegt < 1/127 -> Cosine-Drift gegen fp32 < 0.005.

Caching:
    Berechnete Blobs werden pro (game_slug, model_version) im Prozess-Speicher
    gehalten und nur bei geaenderten Embeddings (max(updated_at)) neu gebaut.
    Bei mehreren Workern (Uvicorn --workers) berechnet jeder Worker einmal pro
    Game; das ist akzeptabel, weil das Blob bei 16 MB nicht teuer ist.
"""
from __future__ import annotations

import asyncio
import hashlib
import struct
import uuid
from dataclasses import dataclass
from datetime import datetime

import numpy as np
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.db.session import get_session
from app.infra.models import Card, CardEmbedding, Game

router = APIRouter(prefix="/embeddings", tags=["embeddings"])

_MAGIC = b"OMAE"
_VERSION = 1
_FLAG_INT8 = 0x01
_HEADER_BYTES = 4 + 4 * 4 + 32 + 32  # 84
_MODEL_VER_FIELD = 32
_GAME_SLUG_FIELD = 32


@dataclass(frozen=True)
class _CachedSnapshot:
    etag: str
    body: bytes
    model_version: str
    count: int
    dim: int
    latest_updated_at: datetime


_cache: dict[tuple[str, str | None], _CachedSnapshot] = {}
_cache_lock = asyncio.Lock()


def _pad_ascii(value: str, length: int) -> bytes:
    raw = value.encode("ascii", errors="replace")
    if len(raw) > length:
        raise ValueError(f"value {value!r} exceeds {length} bytes")
    return raw.ljust(length, b"\x00")


def _compute_etag(model_version: str, count: int, latest: datetime, game_slug: str) -> str:
    payload = f"{model_version}|{count}|{latest.isoformat()}|{game_slug}".encode()
    return hashlib.sha256(payload).hexdigest()[:32]


async def _build_snapshot(
    session: AsyncSession,
    game_slug: str,
    model_version: str | None,
) -> _CachedSnapshot | None:
    """Liest alle Embeddings aus der DB und baut das Binaer-Blob.

    Returns None wenn kein Embedding fuer den Game-Slug existiert.
    """
    settings = get_settings()
    dim = settings.ml_embedding_dim

    stmt = (
        select(
            CardEmbedding.card_id,
            CardEmbedding.vector,
            CardEmbedding.model_version,
            CardEmbedding.updated_at,
        )
        .join(Card, Card.id == CardEmbedding.card_id)
        .join(Game, Game.id == Card.game_id)
        .where(Game.slug == game_slug)
    )
    if model_version:
        stmt = stmt.where(CardEmbedding.model_version == model_version)
    stmt = stmt.order_by(CardEmbedding.card_id)

    rows = (await session.execute(stmt)).all()
    if not rows:
        return None

    n = len(rows)
    actual_model = rows[0].model_version
    latest = rows[0].updated_at
    ids = np.empty((n, 16), dtype=np.uint8)
    matrix = np.empty((n, dim), dtype=np.float32)

    for i, row in enumerate(rows):
        if row.updated_at > latest:
            latest = row.updated_at
        ids[i] = np.frombuffer(row.card_id.bytes, dtype=np.uint8)
        vec = row.vector
        if isinstance(vec, np.ndarray):
            arr = vec.astype(np.float32, copy=False)
        else:
            arr = np.asarray(list(vec), dtype=np.float32)
        if arr.shape != (dim,):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"unexpected vector shape {arr.shape} for card {row.card_id}",
            )
        matrix[i] = arr

    # Per-Vektor symmetrische INT8-Quantisierung.
    max_abs = np.max(np.abs(matrix), axis=1)
    safe_max = np.where(max_abs > 1e-8, max_abs, 1.0).astype(np.float32)
    scales = (safe_max / 127.0).astype(np.float32)
    quantized = np.round(matrix / scales[:, None]).clip(-127, 127).astype(np.int8)

    header = bytearray()
    header.extend(_MAGIC)
    header.extend(struct.pack("<IIII", _VERSION, n, dim, _FLAG_INT8))
    header.extend(_pad_ascii(actual_model, _MODEL_VER_FIELD))
    header.extend(_pad_ascii(game_slug, _GAME_SLUG_FIELD))
    assert len(header) == _HEADER_BYTES, len(header)

    body = bytes(header) + ids.tobytes() + scales.tobytes() + quantized.tobytes()
    etag = _compute_etag(actual_model, n, latest, game_slug)
    return _CachedSnapshot(
        etag=etag,
        body=body,
        model_version=actual_model,
        count=n,
        dim=dim,
        latest_updated_at=latest,
    )


async def _get_or_build_snapshot(
    session: AsyncSession,
    game_slug: str,
    model_version: str | None,
) -> _CachedSnapshot | None:
    """Liefert das Snapshot aus dem Memory-Cache wenn DB-Stand unveraendert ist."""
    cache_key = (game_slug, model_version)
    cached = _cache.get(cache_key)

    # Check ob die DB seit dem Cache-Eintrag aktualisiert wurde.
    stale_stmt = (
        select(func.max(CardEmbedding.updated_at), func.count(CardEmbedding.id))
        .join(Card, Card.id == CardEmbedding.card_id)
        .join(Game, Game.id == Card.game_id)
        .where(Game.slug == game_slug)
    )
    if model_version:
        stale_stmt = stale_stmt.where(CardEmbedding.model_version == model_version)
    row = (await session.execute(stale_stmt)).one()
    latest_db: datetime | None = row[0]
    count_db: int = row[1] or 0

    if cached and latest_db is not None:
        if cached.latest_updated_at == latest_db and cached.count == count_db:
            return cached

    if latest_db is None or count_db == 0:
        return None

    async with _cache_lock:
        cached = _cache.get(cache_key)
        if cached and cached.latest_updated_at == latest_db and cached.count == count_db:
            return cached
        built = await _build_snapshot(session, game_slug, model_version)
        if built is not None:
            _cache[cache_key] = built
        return built


def _strip_etag(value: str | None) -> str | None:
    if not value:
        return None
    return value.strip().strip('"').lstrip("W/").strip('"')


@router.get(
    "/snapshot",
    responses={
        200: {"content": {"application/octet-stream": {}}},
        304: {"description": "Client snapshot is up-to-date"},
        404: {"description": "No embeddings for game_slug"},
    },
)
async def get_snapshot(
    request: Request,
    game_slug: str = Query("pokemon", min_length=1, max_length=_GAME_SLUG_FIELD),
    model_version: str | None = Query(default=None, max_length=_MODEL_VER_FIELD),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """GET /api/v1/embeddings/snapshot – kompaktes Embedding-Blob fuer den Client.

    Optionaler ``If-None-Match``-Header liefert 304 wenn der Client bereits den
    aktuellen Snapshot besitzt.
    """
    cached = await _get_or_build_snapshot(session, game_slug, model_version)
    if cached is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"keine Embeddings fuer game_slug={game_slug}",
        )

    client_etag = _strip_etag(request.headers.get("if-none-match"))
    common_headers = {
        "ETag": f'"{cached.etag}"',
        "Cache-Control": "private, max-age=86400, must-revalidate",
        "X-Model-Version": cached.model_version,
        "X-Snapshot-Count": str(cached.count),
        "X-Snapshot-Dim": str(cached.dim),
        "X-Snapshot-Updated-At": cached.latest_updated_at.isoformat(),
    }
    if client_etag and client_etag == cached.etag:
        return Response(status_code=status.HTTP_304_NOT_MODIFIED, headers=common_headers)

    return Response(
        content=cached.body,
        media_type="application/octet-stream",
        headers=common_headers,
    )


@router.get("/snapshot/meta")
async def get_snapshot_meta(
    game_slug: str = Query("pokemon", min_length=1, max_length=_GAME_SLUG_FIELD),
    model_version: str | None = Query(default=None, max_length=_MODEL_VER_FIELD),
    session: AsyncSession = Depends(get_session),
) -> dict[str, object]:
    """GET /api/v1/embeddings/snapshot/meta – ETag/Count fuer Update-Polling
    ohne den Blob herunterzuladen."""
    cached = await _get_or_build_snapshot(session, game_slug, model_version)
    if cached is None:
        return {"count": 0, "game_slug": game_slug}
    return {
        "etag": cached.etag,
        "count": cached.count,
        "dim": cached.dim,
        "model_version": cached.model_version,
        "game_slug": game_slug,
        "updated_at": cached.latest_updated_at.isoformat(),
    }


def _uuid_from_offset(blob: bytes, offset: int) -> uuid.UUID:
    """Helper fuer Tests – baut UUID aus 16 Bytes ab ``offset`` im Blob."""
    return uuid.UUID(bytes=blob[offset : offset + 16])
