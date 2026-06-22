"""Smoke-Tests fuer /api/v1/embeddings/snapshot.

Wir setzen voraus, dass die DB Embeddings fuer ``pokemon`` enthaelt (siehe
``ml/ml/embedder/build_index.py``); andernfalls liefert der Endpoint 404.
Der Test ist tolerant: bei leerer DB wird er als skipped markiert.
"""
from __future__ import annotations

import struct
import uuid

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


async def _get(client: AsyncClient, path: str, **kwargs):
    return await client.get(path, **kwargs)


async def test_snapshot_meta_returns_count() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await _get(
            client, "/api/v1/embeddings/snapshot/meta?game_slug=pokemon"
        )
    assert response.status_code == 200
    payload = response.json()
    assert "count" in payload
    if payload["count"] == 0:
        pytest.skip("keine Embeddings in der Test-DB")
    assert payload["etag"]
    assert payload["dim"] == 384


async def test_snapshot_binary_format_is_valid() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        meta = await _get(
            client, "/api/v1/embeddings/snapshot/meta?game_slug=pokemon"
        )
        if meta.json().get("count", 0) == 0:
            pytest.skip("keine Embeddings in der Test-DB")
        response = await _get(
            client, "/api/v1/embeddings/snapshot?game_slug=pokemon"
        )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/octet-stream")
    blob = response.content

    # Header pruefen.
    assert blob[:4] == b"OMAE"
    version, count, dim, flags = struct.unpack_from("<IIII", blob, 4)
    assert version == 1
    assert dim == 384
    assert flags & 0x01
    assert count > 0

    expected_size = 84 + count * 16 + count * 4 + count * dim
    assert len(blob) == expected_size

    # Mindestens die erste UUID sollte parsebar sein.
    first_id = uuid.UUID(bytes=bytes(blob[84:100]))
    assert first_id.version == 4 or first_id.version is None

    # ETag-Roundtrip: erneuter Request mit If-None-Match liefert 304.
    etag = response.headers["etag"].strip('"')
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c2:
        response2 = await _get(
            c2,
            "/api/v1/embeddings/snapshot?game_slug=pokemon",
            headers={"If-None-Match": f'"{etag}"'},
        )
    assert response2.status_code == 304
    assert response2.headers["etag"].strip('"') == etag


async def test_snapshot_404_for_unknown_game() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await _get(
            client, "/api/v1/embeddings/snapshot?game_slug=nonexistent-game-xyz"
        )
    assert response.status_code == 404


async def test_cards_lookup_returns_empty_for_unknown_ids() -> None:
    transport = ASGITransport(app=app)
    payload = {"card_ids": ["00000000-0000-0000-0000-000000000000"]}
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post("/api/v1/cards/lookup", json=payload)
    assert response.status_code == 200
    assert response.json() == {"cards": []}


async def test_cards_lookup_422_for_invalid_payload() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post("/api/v1/cards/lookup", json={"card_ids": []})
    assert response.status_code == 422
