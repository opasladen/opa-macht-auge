"""Aggregator-Router fuer v1."""
from __future__ import annotations

from fastapi import APIRouter

from app.api.v1 import cards, health, identify, prices, snapshots

api_v1 = APIRouter(prefix="/api/v1")
api_v1.include_router(health.router)
api_v1.include_router(cards.router)
api_v1.include_router(identify.router)
api_v1.include_router(prices.router)
api_v1.include_router(snapshots.router)
