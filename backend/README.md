# Backend - Opa macht Auge

FastAPI Service fuer Karten-Identifikation und Preis-Aggregation.

## Lokal starten

```powershell
# Aus Repo-Root: docker compose up -d  (Postgres + Redis)

uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --reload
```

Swagger UI: http://localhost:8000/docs

## Struktur

```
app/
  api/v1/         HTTP-Endpunkte (router pro Domain)
  core/           Settings, Logging, Security
  db/             Session, Base, Migration-Anbindung
  domain/         Reine Entities + Wertobjekte (kein I/O)
  infra/          SQLAlchemy-Modelle, Repository-Implementierungen
  services/       Anwendungslogik (Identifikation, Preis-Aggregator)
alembic/          Migrationen (Autogenerate aktiv)
tests/            Pytest
```
