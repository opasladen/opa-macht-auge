# Opa macht Auge - Task Runner
# Verwendung: `just <task>`. Installation: https://github.com/casey/just

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]
set dotenv-load := true

default:
    @just --list

# --- Infrastruktur ---------------------------------------------------------

up:
    docker compose up -d

down:
    docker compose down

logs:
    docker compose logs -f --tail=200

psql:
    docker compose exec postgres psql -U $env:POSTGRES_USER -d $env:POSTGRES_DB

# --- Backend ---------------------------------------------------------------

backend-install:
    cd backend; uv sync

backend-migrate:
    cd backend; uv run alembic upgrade head

backend-makemigration message:
    cd backend; uv run alembic revision --autogenerate -m "{{message}}"

backend-dev:
    cd backend; uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

backend-test:
    cd backend; uv run pytest -q

backend-lint:
    cd backend; uv run ruff check . ; uv run ruff format --check .

backend-format:
    cd backend; uv run ruff format . ; uv run ruff check --fix .

# --- ML --------------------------------------------------------------------

ml-install:
    cd ml; uv sync

ml-bootstrap-pokemon:
    cd ml; uv run python -m ml.bootstrap.pokemontcg

# Cardmarket-Katalog herunterladen + IDs mappen (auto-refresh-ready).
# Bei neuen Pokemon-Sets einfach erneut aufrufen - idempotent.
cm-refresh:
    cd ml; $env:PYTHONPATH = "..\backend"; $env:PYTHONIOENCODING = "utf-8"; uv run python -m ml.bootstrap.cardmarket_catalog refresh

cm-report:
    cd ml; $env:PYTHONPATH = "..\backend"; $env:PYTHONIOENCODING = "utf-8"; uv run python -m ml.bootstrap.cardmarket_catalog report

# --- App -------------------------------------------------------------------

app-get:
    cd app; flutter pub get

app-run:
    cd app; flutter run

app-build-release-android:
    cd app; flutter build apk --release

app-test:
    cd app; flutter test

# --- OpenAPI ---------------------------------------------------------------

openapi-lint:
    npx @redocly/cli lint shared/openapi.yaml

openapi-gen-dart:
    npx @openapitools/openapi-generator-cli generate -i shared/openapi.yaml -g dart-dio -o app/lib/data/remote/generated
