"""Smoke-Tests fuer /cards und /prices (Erreichbarkeit + 404-Verhalten)."""
from __future__ import annotations

from httpx import ASGITransport, AsyncClient

from app.main import app

ZERO_UUID = "00000000-0000-0000-0000-000000000000"


async def test_cards_get_404_for_unknown() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(f"/api/v1/cards/{ZERO_UUID}")
    assert response.status_code == 404
    assert ZERO_UUID in response.json()["detail"]


async def test_prices_card_404_for_unknown() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(f"/api/v1/prices/cards/{ZERO_UUID}")
    assert response.status_code == 404
    assert "card" in response.json()["detail"].lower()


async def test_prices_variant_404_for_unknown() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(f"/api/v1/prices/variants/{ZERO_UUID}")
    assert response.status_code == 404
    assert "variant" in response.json()["detail"].lower()


async def test_cards_get_422_for_invalid_uuid() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/v1/cards/not-a-uuid")
    assert response.status_code == 422
