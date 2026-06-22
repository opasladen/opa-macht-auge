"""Bootstrap-Skript: Pokemon-Master-Index aus pokemontcg.io in Postgres laden.

Verwendung:
    uv run python -m ml.bootstrap.pokemontcg
    uv run python -m ml.bootstrap.pokemontcg --limit 250 --set-code base1

Strategie:
- Sets paginiert ziehen (`/v2/sets`)
- Cards pro Set paginiert ziehen (`/v2/cards?q=set.id:{id}`)
- Idempotenter Upsert ueber (set_code, number)
- Bilder werden NICHT direkt heruntergeladen; nur URLs werden persistiert.
  Download separat ueber `embedder.build_index` als batched Job.
"""
from __future__ import annotations

import sys
import uuid
from datetime import date

import httpx
import typer
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn
from sqlalchemy import create_engine, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session
from tenacity import retry, stop_after_attempt, wait_exponential

from ml.config import get_settings

# Wir importieren die ORM-Modelle aus dem Backend-Paket. Damit gibt es genau
# ein Schema. Voraussetzung: `backend/` ist im PYTHONPATH (siehe README).
try:
    from app.infra.models import Card, CardSet, Game  # type: ignore[import-not-found]
except ImportError:
    sys.stderr.write(
        "Backend-Modelle nicht importierbar. Setze PYTHONPATH:\n"
        '  $env:PYTHONPATH = "../backend"\n'
    )
    raise

POKEMONTCG_BASE = "https://api.pokemontcg.io/v2"
GAME_SLUG = "pokemon"

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


def _client(api_key: str | None) -> httpx.Client:
    headers = {"X-Api-Key": api_key} if api_key else {}
    return httpx.Client(base_url=POKEMONTCG_BASE, headers=headers, timeout=30.0)


@retry(stop=stop_after_attempt(5), wait=wait_exponential(min=1, max=20))
def _get(client: httpx.Client, path: str, params: dict | None = None) -> dict:
    response = client.get(path, params=params)
    response.raise_for_status()
    return response.json()


def _ensure_game(session: Session) -> uuid.UUID:
    game = session.execute(select(Game).where(Game.slug == GAME_SLUG)).scalar_one_or_none()
    if game:
        return game.id
    game = Game(slug=GAME_SLUG, name="Pokemon TCG")
    session.add(game)
    session.flush()
    return game.id


def _upsert_set(session: Session, game_id: uuid.UUID, raw: dict) -> uuid.UUID:
    release = None
    if raw.get("releaseDate"):
        release = date.fromisoformat(raw["releaseDate"].replace("/", "-"))

    stmt = (
        insert(CardSet)
        .values(
            id=uuid.uuid4(),
            game_id=game_id,
            code=raw["id"],
            name=raw["name"],
            language="en",  # pokemontcg.io liefert primaer EN-Sets
            release_date=release,
            total_cards=raw.get("total"),
            printed_total=raw.get("printedTotal"),
            symbol_asset_url=(raw.get("images") or {}).get("symbol"),
        )
        .on_conflict_do_update(
            constraint="uq_card_sets_game_code_lang",
            set_={
                "name": raw["name"],
                "release_date": release,
                "total_cards": raw.get("total"),
                "printed_total": raw.get("printedTotal"),
                "symbol_asset_url": (raw.get("images") or {}).get("symbol"),
            },
        )
        .returning(CardSet.id)
    )
    return session.execute(stmt).scalar_one()


def _upsert_card(session: Session, game_id: uuid.UUID, set_id: uuid.UUID, raw: dict) -> None:
    stmt = (
        insert(Card)
        .values(
            id=uuid.uuid4(),
            game_id=game_id,
            set_id=set_id,
            number=str(raw["number"]),
            name_localized={"en": raw["name"]},
            rarity=raw.get("rarity"),
            card_type=(raw.get("supertype") or "").lower() or None,
            image_url_small=(raw.get("images") or {}).get("small"),
            image_url_large=(raw.get("images") or {}).get("large"),
            external_id=raw["id"],
        )
        .on_conflict_do_update(
            constraint="uq_cards_set_number",
            set_={
                "name_localized": {"en": raw["name"]},
                "rarity": raw.get("rarity"),
                "card_type": (raw.get("supertype") or "").lower() or None,
                "image_url_small": (raw.get("images") or {}).get("small"),
                "image_url_large": (raw.get("images") or {}).get("large"),
                "external_id": raw["id"],
            },
        )
    )
    session.execute(stmt)


@app.command()
def main(
    limit: int = typer.Option(0, help="Maximale Anzahl Karten gesamt (0 = unbegrenzt)"),
    set_code: str | None = typer.Option(None, help="Nur dieses Set importieren (z.B. base1)"),
    page_size: int = typer.Option(250, help="API page size"),
) -> None:
    """Importiert Sets und Karten von pokemontcg.io in die lokale Postgres."""
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)
    imported = 0

    with _client(settings.pokemontcg_api_key) as http, Session(engine) as session:
        game_id = _ensure_game(session)
        session.commit()

        sets_payload = _get(http, "/sets", params={"pageSize": 250})
        sets = sets_payload.get("data", [])
        if set_code:
            sets = [s for s in sets if s["id"] == set_code]

        console.print(f"[bold]{len(sets)}[/bold] Sets gefunden.")

        with Progress(SpinnerColumn(), TextColumn("{task.description}"), console=console) as bar:
            task = bar.add_task("Importing", total=len(sets))
            for s in sets:
                set_id = _upsert_set(session, game_id, s)
                session.commit()

                page = 1
                while True:
                    payload = _get(
                        http,
                        "/cards",
                        params={
                            "q": f"set.id:{s['id']}",
                            "page": page,
                            "pageSize": page_size,
                        },
                    )
                    cards = payload.get("data", [])
                    if not cards:
                        break
                    for c in cards:
                        _upsert_card(session, game_id, set_id, c)
                        imported += 1
                        if limit and imported >= limit:
                            session.commit()
                            console.print(f"[green]Limit erreicht: {imported} Karten[/green]")
                            return
                    session.commit()
                    if len(cards) < page_size:
                        break
                    page += 1

                bar.update(task, advance=1, description=f"{s['id']} ({imported} Karten)")

        console.print(f"[green]Fertig. Importierte Karten: {imported}[/green]")


if __name__ == "__main__":
    app()
