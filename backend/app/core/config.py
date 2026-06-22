"""Application-wide configuration loaded from environment variables."""
from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import Field, PostgresDsn, RedisDsn, computed_field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # --- App ---------------------------------------------------------------
    app_env: Literal["development", "staging", "production", "test"] = "development"
    app_secret_key: str = Field(min_length=32)
    app_log_level: str = "INFO"
    app_cors_origins: list[str] = Field(default_factory=list)

    # --- Postgres ----------------------------------------------------------
    postgres_user: str = "opa"
    postgres_password: str = "opa_dev_change_me"
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_db: str = "opa_macht_auge"

    # --- Redis -------------------------------------------------------------
    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_password: str | None = None

    # --- Externe APIs ------------------------------------------------------
    pokemontcg_api_key: str | None = None
    cardmarket_app_token: str | None = None
    cardmarket_app_secret: str | None = None
    cardmarket_access_token: str | None = None
    cardmarket_access_token_secret: str | None = None
    ebay_app_id: str | None = None
    ebay_cert_id: str | None = None
    ebay_dev_id: str | None = None

    # --- ML ----------------------------------------------------------------
    ml_embedding_dim: int = 384

    @computed_field  # type: ignore[prop-decorator]
    @property
    def database_url(self) -> PostgresDsn:
        return PostgresDsn(
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @computed_field  # type: ignore[prop-decorator]
    @property
    def database_url_sync(self) -> str:
        """Sync DSN fuer Alembic-Migrationen."""
        return (
            f"postgresql+psycopg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @computed_field  # type: ignore[prop-decorator]
    @property
    def redis_url(self) -> RedisDsn:
        auth = f":{self.redis_password}@" if self.redis_password else ""
        return RedisDsn(f"redis://{auth}{self.redis_host}:{self.redis_port}/0")

    @property
    def is_production(self) -> bool:
        return self.app_env == "production"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
