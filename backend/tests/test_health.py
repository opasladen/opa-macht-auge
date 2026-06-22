"""Smoke-Tests fuer die FastAPI-App."""
from __future__ import annotations

from httpx import ASGITransport, AsyncClient

from app.main import app


async def test_liveness() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/v1/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
