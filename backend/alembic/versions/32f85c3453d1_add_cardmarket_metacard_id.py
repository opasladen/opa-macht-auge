"""add cardmarket metacard id

Revision ID: 32f85c3453d1
Revises: 4928e3e09350
Create Date: 2026-06-22 19:43:26.097457

"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "32f85c3453d1"
down_revision: str | Sequence[str] | None = "4928e3e09350"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("cards", sa.Column("cardmarket_metacard_id", sa.Integer(), nullable=True))
    op.create_index(
        op.f("ix_cards_cardmarket_metacard_id"),
        "cards",
        ["cardmarket_metacard_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_cards_cardmarket_metacard_id"), table_name="cards")
    op.drop_column("cards", "cardmarket_metacard_id")
