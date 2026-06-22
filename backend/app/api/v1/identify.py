"""Identifikations-Endpoint: nimmt Embedding vom Client und liefert Top-K Karten.

Architektur-Hinweis: Der Client (Flutter, on-device DINOv2-distilled) berechnet das
Embedding selbst und sendet nur den 384-D-Vektor. Das Backend macht ausschliesslich
die pgvector-HNSW-Suche und persistiert einen Scan-Eintrag fuer Audit.
"""
from __future__ import annotations

import uuid
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.db.session import get_session
from app.infra.models import Card, CardEmbedding, CardSet, Game, Scan

router = APIRouter(prefix="/identify", tags=["identify"])

_EMB_DIM = get_settings().ml_embedding_dim


class IdentifyRequest(BaseModel):
    embedding: list[float] = Field(min_length=_EMB_DIM, max_length=_EMB_DIM)
    model_version: str = Field(min_length=1, max_length=32)
    top_k: int = Field(default=5, ge=1, le=50)
    game_slug: str = "pokemon"
    client_version: str | None = Field(default=None, max_length=32)

    @field_validator("embedding")
    @classmethod
    def _finite(cls, v: list[float]) -> list[float]:
        if any(not _is_finite(x) for x in v):
            raise ValueError("embedding contains non-finite values")
        return v


class IdentifyMatch(BaseModel):
    card_id: str
    similarity: float
    name: str
    set_code: str
    language: str
    number: str
    rarity: str | None = None
    image_url: str | None = None


class IdentifyResponse(BaseModel):
    matches: list[IdentifyMatch]
    model_version: str


def _is_finite(x: float) -> bool:
    return x == x and x not in (float("inf"), float("-inf"))


@router.post("", response_model=IdentifyResponse)
async def identify(
    payload: IdentifyRequest,
    session: AsyncSession = Depends(get_session),
) -> IdentifyResponse:
    distance = CardEmbedding.vector.cosine_distance(payload.embedding).label("distance")

    stmt = (
        select(
            CardEmbedding.card_id,
            CardEmbedding.model_version,
            Card.number,
            Card.name_localized,
            Card.rarity,
            Card.image_url_small,
            CardSet.code.label("set_code"),
            CardSet.language.label("set_language"),
            distance,
        )
        .join(Card, Card.id == CardEmbedding.card_id)
        .join(CardSet, CardSet.id == Card.set_id)
        .join(Game, Game.id == Card.game_id)
        .where(Game.slug == payload.game_slug)
        .order_by(distance)
        .limit(payload.top_k)
    )
    rows = (await session.execute(stmt)).all()

    if not rows:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"keine Embeddings fuer game_slug={payload.game_slug}",
        )

    matches = [
        IdentifyMatch(
            card_id=str(row.card_id),
            similarity=round(1.0 - float(row.distance), 4),
            name=_pick_name(row.name_localized, row.set_language),
            set_code=row.set_code,
            language=row.set_language,
            number=row.number,
            rarity=row.rarity,
            image_url=row.image_url_small,
        )
        for row in rows
    ]

    top = matches[0]
    index_model_version = rows[0].model_version
    session.add(
        Scan(
            id=uuid.uuid4(),
            matched_card_id=uuid.UUID(top.card_id),
            similarity=Decimal(str(top.similarity)),
            client_version=payload.client_version,
            model_version=payload.model_version,
        )
    )

    return IdentifyResponse(matches=matches, model_version=index_model_version)


def _pick_name(localized: dict | None, preferred_lang: str | None = None) -> str:
    if not localized:
        return ""
    lookup = (preferred_lang, "de", "en") if preferred_lang else ("de", "en")
    for lang in lookup:
        if lang and lang in localized:
            return localized[lang]
    return next(iter(localized.values()), "")


class IdentifyByCodeRequest(BaseModel):
    """Deterministischer Lookup ueber die auf der Karte aufgedruckten Felder.

    Mindestens `number` ist erforderlich. Je mehr Felder gesetzt werden, desto
    eindeutiger das Ergebnis. Pflicht-Felder sind absichtlich locker, weil OCR
    nicht jedes Feld immer sauber liest.
    """

    number: str = Field(min_length=1, max_length=16)
    language: str | None = Field(default=None, min_length=2, max_length=2)
    set_code: str | None = Field(default=None, min_length=1, max_length=16)
    printed_total: int | None = Field(default=None, ge=1)
    game_slug: str = "pokemon"


@router.post("-by-code", response_model=IdentifyResponse)
async def identify_by_code(
    payload: IdentifyByCodeRequest,
    session: AsyncSession = Depends(get_session),
) -> IdentifyResponse:
    # Number-Varianten: OCR liefert "111", DB hat ggf. "111" oder "0111" etc.
    raw = payload.number.strip()
    stripped = raw.lstrip("0") or raw
    candidates = {raw, stripped, stripped.zfill(2), stripped.zfill(3), stripped.zfill(4)}

    stmt = (
        select(
            Card.id.label("card_id"),
            Card.number,
            Card.name_localized,
            Card.rarity,
            Card.image_url_small,
            CardSet.code.label("set_code"),
            CardSet.language.label("set_language"),
        )
        .join(CardSet, CardSet.id == Card.set_id)
        .join(Game, Game.id == Card.game_id)
        .where(
            Game.slug == payload.game_slug,
            or_(*(Card.number == c for c in candidates)),
        )
        .order_by(CardSet.release_date.desc().nullslast(), CardSet.code, Card.number)
        .limit(50)
    )
    if payload.language:
        stmt = stmt.where(CardSet.language == payload.language)
    if payload.set_code:
        stmt = stmt.where(CardSet.code == payload.set_code)
    if payload.printed_total is not None:
        stmt = stmt.where(CardSet.printed_total == payload.printed_total)

    rows = (await session.execute(stmt)).all()
    if not rows:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="keine Karte fuer angegebene Felder gefunden",
        )

    matches = [
        IdentifyMatch(
            card_id=str(row.card_id),
            # OCR-Lookup ist deterministisch -> 1.0 bei eindeutigem Hit, sonst
            # 1 / Anzahl-Kandidaten als grobe Konfidenz.
            similarity=round(1.0 / len(rows), 4),
            name=_pick_name(row.name_localized, row.set_language),
            set_code=row.set_code,
            language=row.set_language,
            number=row.number,
            rarity=row.rarity,
            image_url=row.image_url_small,
        )
        for row in rows
    ]

    if len(rows) == 1:
        matches[0] = matches[0].model_copy(update={"similarity": 1.0})

    return IdentifyResponse(matches=matches, model_version="ocr-lookup-v1")
