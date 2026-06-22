"""Pytest configuration."""
from __future__ import annotations

import os
from collections.abc import AsyncIterator

import pytest

os.environ.setdefault("APP_SECRET_KEY", "test_secret_key_minimum_32_chars_ok_ok")
os.environ.setdefault("APP_ENV", "test")


@pytest.fixture(scope="session")
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture(autouse=True)
async def _dispose_engine() -> AsyncIterator[None]:
    """Schliesst den asyncpg-Connection-Pool nach jedem Test.

    Notwendig weil pytest-asyncio (default function-scope) pro Test
    eine neue Event-Loop erzeugt; der modul-global geteilte engine
    wuerde sonst Verbindungen an einer bereits geschlossenen Loop halten.
    """
    yield
    from app.db.session import engine

    await engine.dispose()
