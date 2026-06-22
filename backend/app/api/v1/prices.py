"""Marktpreis-Endpoints.

- GET /prices/variants/{variant_id} -> neueste Preise pro (source, condition)
- GET /prices/cards/{card_id}       -> alle Variants der Karte mit neuesten Preisen
"""
from __future__ import annotations

import uuid
from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._schemas import PriceOut, VariantOut
from app.db.session import get_session
from app.infra.models import CardVariant, Price

router = APIRouter(prefix="/prices", tags=["prices"])


async def _latest_prices(
    session: AsyncSession, variant_ids: list[uuid.UUID]
) -> dict[uuid.UUID, list[PriceOut]]:
    bucket: dict[uuid.UUID, list[PriceOut]] = defaultdict(list)
    if not variant_ids:
        return bucket
    stmt = (
        select(Price)
        .where(Price.variant_id.in_(variant_ids))
        .order_by(
            Price.variant_id,
            Price.source,
            Price.condition,
            Price.fetched_at.desc(),
        )
        .distinct(Price.variant_id, Price.source, Price.condition)
    )
    rows = (await session.execute(stmt)).scalars().all()
    for p in rows:
        bucket[p.variant_id].append(
            PriceOut(
                source=p.source,
                condition=p.condition,
                price_eur=p.price_eur,
                trend_7d_eur=p.trend_7d_eur,
                fetched_at=p.fetched_at,
            )
        )
    return bucket


@router.get("/variants/{variant_id}", response_model=VariantOut)
async def get_variant_prices(
    variant_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
) -> VariantOut:
    variant = await session.get(CardVariant, variant_id)
    if variant is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"variant {variant_id} nicht gefunden",
        )
    prices = (await _latest_prices(session, [variant.id])).get(variant.id, [])
    return VariantOut(
        variant_id=str(variant.id),
        language=variant.language,
        edition=variant.edition,
        finish=variant.finish,
        prices=sorted(prices, key=lambda p: (p.source, p.condition)),
    )


@router.get("/cards/{card_id}", response_model=list[VariantOut])
async def get_card_prices(
    card_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
) -> list[VariantOut]:
    stmt = (
        select(CardVariant)
        .where(CardVariant.card_id == card_id)
        .order_by(CardVariant.language, CardVariant.finish, CardVariant.edition)
    )
    variants = (await session.execute(stmt)).scalars().all()
    if not variants:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"keine Variants fuer card {card_id}",
        )
    prices_by_variant = await _latest_prices(session, [v.id for v in variants])
    return [
        VariantOut(
            variant_id=str(v.id),
            language=v.language,
            edition=v.edition,
            finish=v.finish,
            prices=sorted(
                prices_by_variant.get(v.id, []),
                key=lambda p: (p.source, p.condition),
            ),
        )
        for v in variants
    ]
