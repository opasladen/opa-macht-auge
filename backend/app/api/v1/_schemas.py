"""Gemeinsame Pydantic-Schemas fuer Karten/Preise-Endpoints."""
from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel


class PriceOut(BaseModel):
    source: str
    condition: str
    price_eur: Decimal
    trend_7d_eur: Decimal | None = None
    fetched_at: datetime


class VariantOut(BaseModel):
    variant_id: str
    language: str
    edition: str
    finish: str
    prices: list[PriceOut] = []


class CardOut(BaseModel):
    card_id: str
    set_code: str
    set_name: str
    set_language: str
    number: str
    name_localized: dict[str, str]
    rarity: str | None = None
    card_type: str | None = None
    image_url_small: str | None = None
    image_url_large: str | None = None
    cardmarket_metacard_id: int | None = None
    cardmarket_product_id: int | None = None
    cardmarket_expansion_id: int | None = None
    variants: list[VariantOut] = []
