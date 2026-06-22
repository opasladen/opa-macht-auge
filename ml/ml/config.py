"""Konfiguration der ML-Pipeline (gemeinsam mit Backend ueber .env)."""
from __future__ import annotations

from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class MLSettings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    postgres_user: str = "opa"
    postgres_password: str = "opa_dev_change_me"
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_db: str = "opa_macht_auge"

    pokemontcg_api_key: str | None = None
    ml_embedding_dim: int = 384
    ml_model_registry_path: Path = Path("./weights")

    @property
    def database_url_sync(self) -> str:
        return (
            f"postgresql+psycopg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


def get_settings() -> MLSettings:
    return MLSettings()  # type: ignore[call-arg]
