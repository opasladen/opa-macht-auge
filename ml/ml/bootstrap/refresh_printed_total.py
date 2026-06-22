"""Schreibt `card_sets.printed_total` aus pokemontcg.io nach.

Hintergrund: das urspruengliche Bootstrap-Script hat nur `total` (mit Secret
Rares) persistiert. Auf der gedruckten Karte steht aber `printedTotal`
(z. B. "111/195" fuer Silver Tempest, obwohl der DB-Total 245 ist). Ohne
dieses Feld kann der OCR-Pfad die Karte nicht eindeutig der Set zuordnen.

Iteriert ueber alle Sets von pokemontcg.io und updated jedes lokale CardSet
mit gleicher `code` (sowohl EN als auch DE), so dass keine Karten neu
gezogen werden muessen.

Verwendung:
    uv run python -m ml.bootstrap.refresh_printed_total
"""
from __future__ import annotations

import sys

import httpx
import typer
from rich.console import Console
from sqlalchemy import create_engine, update
from sqlalchemy.orm import Session
from tenacity import retry, stop_after_attempt, wait_exponential

from ml.config import get_settings

try:
    from app.infra.models import CardSet  # type: ignore[import-not-found]
except ImportError:
    sys.stderr.write(
        "Backend-Modelle nicht importierbar. Setze PYTHONPATH:\n"
        '  $env:PYTHONPATH = "../backend"\n'
    )
    raise

POKEMONTCG_BASE = "https://api.pokemontcg.io/v2"

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


@retry(stop=stop_after_attempt(5), wait=wait_exponential(min=1, max=20))
def _get(client: httpx.Client, path: str, params: dict | None = None) -> dict:
    response = client.get(path, params=params)
    response.raise_for_status()
    return response.json()


@app.command()
def main() -> None:
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)
    headers = {"X-Api-Key": settings.pokemontcg_api_key} if settings.pokemontcg_api_key else {}
    updated = 0
    skipped = 0

    with (
        httpx.Client(base_url=POKEMONTCG_BASE, headers=headers, timeout=30.0) as http,
        Session(engine) as session,
    ):
        page = 1
        page_size = 250
        while True:
            payload = _get(http, "/sets", params={"page": page, "pageSize": page_size})
            sets = payload.get("data", [])
            if not sets:
                break

            for s in sets:
                code = s["id"]
                printed = s.get("printedTotal")
                if printed is None:
                    skipped += 1
                    continue
                stmt = (
                    update(CardSet)
                    .where(CardSet.code == code)
                    .values(printed_total=printed)
                )
                result = session.execute(stmt)
                if result.rowcount:
                    updated += result.rowcount
                else:
                    skipped += 1
            session.commit()
            if len(sets) < page_size:
                break
            page += 1

    console.print(f"[green]Updated {updated} card_sets rows; skipped {skipped} sets.[/green]")


if __name__ == "__main__":
    app()
