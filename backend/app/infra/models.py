"""SQLAlchemy ORM-Modelle.

Wichtig: Karten-Identitaet = (set_code, number, language, edition, finish).
Preise haengen an `card_variants`, nicht an `cards` direkt.
"""
from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    Date,
    DateTime,
    ForeignKey,
    Index,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.config import get_settings
from app.db.base import Base, TimestampMixin, UUIDMixin

_EMB_DIM = get_settings().ml_embedding_dim


class Game(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "games"

    slug: Mapped[str] = mapped_column(String(32), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(128), nullable=False)

    sets: Mapped[list["CardSet"]] = relationship(back_populates="game")


class CardSet(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "card_sets"
    __table_args__ = (
        UniqueConstraint("game_id", "code", "language", name="uq_card_sets_game_code_lang"),
        Index("ix_card_sets_release", "release_date"),
    )

    game_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("games.id", ondelete="CASCADE"), nullable=False
    )
    code: Mapped[str] = mapped_column(String(16), nullable=False)
    name: Mapped[str] = mapped_column(String(256), nullable=False)
    language: Mapped[str] = mapped_column(String(2), nullable=False)
    release_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    total_cards: Mapped[int | None] = mapped_column(nullable=True)
    printed_total: Mapped[int | None] = mapped_column(nullable=True)
    symbol_asset_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    cardmarket_expansion_id: Mapped[int | None] = mapped_column(nullable=True, index=True)

    game: Mapped[Game] = relationship(back_populates="sets")
    cards: Mapped[list["Card"]] = relationship(back_populates="card_set")


class Card(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "cards"
    __table_args__ = (
        UniqueConstraint("set_id", "number", name="uq_cards_set_number"),
        Index("ix_cards_artwork_hash", "artwork_hash"),
        Index("ix_cards_name_trgm", "name_localized", postgresql_using="gin"),
    )

    game_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("games.id", ondelete="CASCADE"), nullable=False
    )
    set_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("card_sets.id", ondelete="CASCADE"), nullable=False
    )
    number: Mapped[str] = mapped_column(String(16), nullable=False)
    name_localized: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    rarity: Mapped[str | None] = mapped_column(String(64), nullable=True)
    card_type: Mapped[str | None] = mapped_column(String(64), nullable=True)
    artwork_hash: Mapped[str | None] = mapped_column(String(32), nullable=True)
    image_url_small: Mapped[str | None] = mapped_column(Text, nullable=True)
    image_url_large: Mapped[str | None] = mapped_column(Text, nullable=True)
    external_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    cardmarket_product_id: Mapped[int | None] = mapped_column(nullable=True, index=True)
    cardmarket_metacard_id: Mapped[int | None] = mapped_column(nullable=True, index=True)

    card_set: Mapped[CardSet] = relationship(back_populates="cards")
    variants: Mapped[list["CardVariant"]] = relationship(
        back_populates="card", cascade="all, delete-orphan"
    )
    embedding: Mapped["CardEmbedding | None"] = relationship(
        back_populates="card", uselist=False, cascade="all, delete-orphan"
    )


class CardVariant(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "card_variants"
    __table_args__ = (
        UniqueConstraint(
            "card_id",
            "language",
            "edition",
            "finish",
            name="uq_card_variants_identity",
        ),
    )

    card_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cards.id", ondelete="CASCADE"), nullable=False
    )
    language: Mapped[str] = mapped_column(String(2), nullable=False)
    edition: Mapped[str] = mapped_column(String(32), nullable=False)
    finish: Mapped[str] = mapped_column(String(32), nullable=False)

    card: Mapped[Card] = relationship(back_populates="variants")
    prices: Mapped[list["Price"]] = relationship(
        back_populates="variant", cascade="all, delete-orphan"
    )


class CardEmbedding(UUIDMixin, TimestampMixin, Base):
    """Visuelles Embedding pro Karte. HNSW-Index ueber pgvector."""

    __tablename__ = "card_embeddings"
    __table_args__ = (
        Index(
            "ix_card_embeddings_vector_hnsw",
            "vector",
            postgresql_using="hnsw",
            postgresql_with={"m": 16, "ef_construction": 64},
            postgresql_ops={"vector": "vector_cosine_ops"},
        ),
    )

    card_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("cards.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    model_version: Mapped[str] = mapped_column(String(32), nullable=False)
    vector: Mapped[list[float]] = mapped_column(Vector(_EMB_DIM), nullable=False)

    card: Mapped[Card] = relationship(back_populates="embedding")


class Price(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "prices"
    __table_args__ = (
        Index("ix_prices_variant_fetched", "variant_id", "fetched_at"),
        Index("ix_prices_source", "source"),
    )

    variant_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("card_variants.id", ondelete="CASCADE"),
        nullable=False,
    )
    source: Mapped[str] = mapped_column(String(32), nullable=False)
    condition: Mapped[str] = mapped_column(String(8), nullable=False)
    price_eur: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    trend_7d_eur: Mapped[Decimal | None] = mapped_column(Numeric(12, 2), nullable=True)
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    variant: Mapped[CardVariant] = relationship(back_populates="prices")


class Scan(UUIDMixin, TimestampMixin, Base):
    """Auditing-Tabelle fuer Client-Identifikationsanfragen (opt-in)."""

    __tablename__ = "scans"

    matched_card_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("cards.id", ondelete="SET NULL"), nullable=True
    )
    similarity: Mapped[Decimal | None] = mapped_column(Numeric(5, 4), nullable=True)
    client_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    model_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
