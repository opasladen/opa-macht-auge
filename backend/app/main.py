"""FastAPI Anwendungsbootstrap."""
from __future__ import annotations

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.v1.router import api_v1
from app.core.config import get_settings
from app.core.logging import configure_logging, get_logger


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    configure_logging(settings.app_log_level)
    log = get_logger("startup")
    log.info("app.start", env=settings.app_env)
    yield
    log.info("app.stop")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="Opa macht Auge",
        version="0.1.0",
        description="Karten-Identifikation und Marktpreis-Intelligenz",
        lifespan=lifespan,
        docs_url="/docs" if not settings.is_production else None,
        redoc_url=None,
    )

    if settings.app_cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.app_cors_origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_handler(
        _request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        # input/ctx strippen: vermeidet JSON-Encoding-Fehler bei NaN/Inf-Werten
        # und nicht-serialisierbaren Exception-Objekten im ctx.
        errors = [
            {k: v for k, v in err.items() if k not in ("input", "ctx")}
            for err in exc.errors()
        ]
        return JSONResponse(status_code=422, content={"detail": errors})

    app.include_router(api_v1)
    return app


app = create_app()
