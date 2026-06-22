"""Card-Detail-Endpoint: Karte + Set + Variants + neueste Preise."""
from __future__ import annotations

import uuid
from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import Text, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1._schemas import CardOut, PriceOut, VariantOut
from app.db.session import get_session
from app.infra.models import Card, CardSet, CardVariant, Price

router = APIRouter(prefix="/cards", tags=["cards"])


class CardLookupRequest(BaseModel):
    """Batch-Lookup fuer TopK-Hydration nach dem On-Device-Index-Match."""

    card_ids: list[uuid.UUID] = Field(min_length=1, max_length=50)


class CardSummary(BaseModel):
    card_id: str
    name: str
    set_code: str
    set_language: str
    number: str
    rarity: str | None = None
    image_url_small: str | None = None
    cardmarket_metacard_id: int | None = None
    cardmarket_product_id: int | None = None
    cardmarket_expansion_id: int | None = None


class CardLookupResponse(BaseModel):
    cards: list[CardSummary]


@router.post("/lookup", response_model=CardLookupResponse)
async def lookup_cards(
    payload: CardLookupRequest,
    session: AsyncSession = Depends(get_session),
) -> CardLookupResponse:
    """POST /api/v1/cards/lookup – kompakte Metadaten fuer eine Liste von IDs.

    Wird vom Flutter-Client nach dem lokalen TopK-Match aufgerufen um
    Name/Set/Number/Image fuer die Anzeige zu hydrieren. Antwortgroesse ist
    klein (~200 B pro Karte), kein Joining ueber Preise/Variants.
    Die Reihenfolge der Antwort entspricht der Reihenfolge in ``card_ids``;
    nicht gefundene IDs werden uebersprungen.
    """
    stmt = (
        select(
            Card.id,
            Card.number,
            Card.name_localized,
            Card.rarity,
            Card.image_url_small,
            Card.cardmarket_metacard_id,
            Card.cardmarket_product_id,
            CardSet.code.label("set_code"),
            CardSet.language.label("set_language"),
            CardSet.cardmarket_expansion_id,
        )
        .join(CardSet, CardSet.id == Card.set_id)
        .where(Card.id.in_(payload.card_ids))
    )
    rows = (await session.execute(stmt)).all()
    by_id = {row.id: row for row in rows}

    summaries: list[CardSummary] = []
    for cid in payload.card_ids:
        row = by_id.get(cid)
        if row is None:
            continue
        summaries.append(
            CardSummary(
                card_id=str(row.id),
                name=_pick_localized_name(row.name_localized, row.set_language),
                set_code=row.set_code,
                set_language=row.set_language,
                number=row.number,
                rarity=row.rarity,
                image_url_small=row.image_url_small,
                cardmarket_metacard_id=row.cardmarket_metacard_id,
                cardmarket_product_id=row.cardmarket_product_id,
                cardmarket_expansion_id=row.cardmarket_expansion_id,
            )
        )
    return CardLookupResponse(cards=summaries)


@router.get("/search", response_model=CardLookupResponse)
async def search_cards(
    q: str = Query(..., min_length=1, max_length=80, description="Name oder Set/Number"),
    language: str | None = Query(None, max_length=4, description="ISO-Sprachfilter (de, en, ja, ...)"),
    limit: int = Query(20, ge=1, le=50),
    session: AsyncSession = Depends(get_session),
) -> CardLookupResponse:
    """GET /api/v1/cards/search?q=...&language=de&limit=20

    Freie Karten-Suche fuer Korrektur-Workflows im Client (z. B. „Verlauf-
    Eintrag manuell korrigieren"). Sucht case-insensitiv im JSONB-Feld
    `name_localized` (alle Sprachen) sowie im Set-Code und in der
    Card-Number. Resultat ist die gleiche kompakte Struktur wie bei
    /lookup, damit der Client keine zweite DTO-Variante braucht.
    """
    pattern = f"%{q.lower()}%"
    stmt = (
        select(
            Card.id,
            Card.number,
            Card.name_localized,
            Card.rarity,
            Card.image_url_small,
            Card.cardmarket_metacard_id,
            Card.cardmarket_product_id,
            CardSet.code.label("set_code"),
            CardSet.language.label("set_language"),
            CardSet.cardmarket_expansion_id,
        )
        .join(CardSet, CardSet.id == Card.set_id)
        .where(
            or_(
                # JSONB-Werte als Text casten und case-insensitiv matchen.
                Card.name_localized.cast(Text).ilike(pattern),
                CardSet.code.ilike(pattern),
                Card.number.ilike(pattern),
            )
        )
        .limit(limit)
    )
    if language:
        stmt = stmt.where(CardSet.language == language.lower())

    rows = (await session.execute(stmt)).all()
    summaries = [
        CardSummary(
            card_id=str(row.id),
            name=_pick_localized_name(row.name_localized, row.set_language),
            set_code=row.set_code,
            set_language=row.set_language,
            number=row.number,
            rarity=row.rarity,
            image_url_small=row.image_url_small,
            cardmarket_metacard_id=row.cardmarket_metacard_id,
            cardmarket_product_id=row.cardmarket_product_id,
            cardmarket_expansion_id=row.cardmarket_expansion_id,
        )
        for row in rows
    ]
    return CardLookupResponse(cards=summaries)


def _pick_localized_name(localized: dict | None, preferred_lang: str | None) -> str:
    if not localized:
        return ""
    lookup = (preferred_lang, "de", "en") if preferred_lang else ("de", "en")
    for lang in lookup:
        if lang and lang in localized:
            return localized[lang]
    return next(iter(localized.values()), "")


# WICHTIG: `/{card_id}` MUSS nach den literalen Routen `/search` und
# `/lookup` registriert werden, sonst werden Anfragen wie `GET /search`
# auf die UUID-typisierte Route geleitet und liefern HTTP 422.
@router.get("/{card_id}", response_model=CardOut)
async def get_card(
    card_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
) -> CardOut:
    card_stmt = (
        select(Card, CardSet)
        .join(CardSet, CardSet.id == Card.set_id)
        .where(Card.id == card_id)
    )
    row = (await session.execute(card_stmt)).first()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"card {card_id} nicht gefunden",
        )
    card, card_set = row

    variant_stmt = (
        select(CardVariant)
        .where(CardVariant.card_id == card_id)
        .order_by(CardVariant.language, CardVariant.finish, CardVariant.edition)
    )
    variants = (await session.execute(variant_stmt)).scalars().all()

    prices_by_variant: dict[uuid.UUID, list[PriceOut]] = defaultdict(list)
    if variants:
        variant_ids = [v.id for v in variants]
        # DISTINCT ON liefert neuesten Preis pro (variant, source, condition)
        price_stmt = (
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
        prices = (await session.execute(price_stmt)).scalars().all()
        for p in prices:
            prices_by_variant[p.variant_id].append(
                PriceOut(
                    source=p.source,
                    condition=p.condition,
                    price_eur=p.price_eur,
                    trend_7d_eur=p.trend_7d_eur,
                    fetched_at=p.fetched_at,
                )
            )

    return CardOut(
        card_id=str(card.id),
        set_code=card_set.code,
        set_name=card_set.name,
        set_language=card_set.language,
        number=card.number,
        name_localized=card.name_localized or {},
        rarity=card.rarity,
        card_type=card.card_type,
        image_url_small=card.image_url_small,
        image_url_large=card.image_url_large,
        cardmarket_metacard_id=card.cardmarket_metacard_id,
        cardmarket_product_id=card.cardmarket_product_id,
        cardmarket_expansion_id=card_set.cardmarket_expansion_id,
        variants=[
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
        ],
    )
