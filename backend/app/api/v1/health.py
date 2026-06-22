"""Health and readiness probes."""
from __future__ import annotations

from fastapi import APIRouter, Depends, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_session

router = APIRouter(tags=["health"])


@router.get("/healthz", status_code=status.HTTP_200_OK)
async def liveness() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz", status_code=status.HTTP_200_OK)
async def readiness(session: AsyncSession = Depends(get_session)) -> dict[str, str]:
    await session.execute(text("SELECT 1"))
    return {"status": "ready"}
