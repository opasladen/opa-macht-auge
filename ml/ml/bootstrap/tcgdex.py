"""Bootstrap aus TCGdex: multilinguale Sets und Karten (DE/EN/JP/...).

Verwendung:
    uv run python -m ml.bootstrap.tcgdex
    uv run python -m ml.bootstrap.tcgdex --languages en,de,ja
    uv run python -m ml.bootstrap.tcgdex --languages de --sets base1,base2
    uv run python -m ml.bootstrap.tcgdex --languages en --include-no-image

Strategie:
- Pro Sprache: GET /v2/{lang}/sets fuer die Set-Liste
- Pro Set: GET /v2/{lang}/sets/{id} liefert direkt alle Karten mit
  `localId`, `name`, `image` (Basis-URL ohne Extension).
- Image-URL-Konstruktion: `{image}/low.webp` (Preview) und
  `{image}/high.webp` (Embedder-Eingabe).
- card_sets ist sprachspezifisch (game_id, code, language) - eine deutsche
  Base-Set-Row ist unabhaengig von der englischen.
- Idempotenter Upsert ueber bestehende Unique-Constraints.
"""
from __future__ import annotations

import asyncio
import sys
import uuid
from datetime import date

import httpx
import typer
from rich.console import Console
from rich.progress import (
    BarColumn,
    MofNCompleteColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
)
from sqlalchemy import create_engine, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session
from tenacity import AsyncRetrying, retry_if_exception_type, stop_after_attempt, wait_exponential

from ml.config import get_settings

try:
    from app.infra.models import Card, CardSet, Game  # type: ignore[import-not-found]
except ImportError:
    sys.stderr.write(
        "Backend-Modelle nicht importierbar. Setze PYTHONPATH:\n"
        '  $env:PYTHONPATH = "../backend"\n'
    )
    raise

TCGDEX_BASE = "https://api.tcgdex.net/v2"
GAME_SLUG = "pokemon"
DEFAULT_LANGS = "en,de,ja"

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


async def _get_json(client: httpx.AsyncClient, url: str) -> dict | list:
    async for attempt in AsyncRetrying(
        stop=stop_after_attempt(4),
        wait=wait_exponential(min=1, max=15),
        retry=retry_if_exception_type(
            (httpx.TransportError, httpx.HTTPStatusError, httpx.TimeoutException)
        ),
        reraise=True,
    ):
        with attempt:
            response = await client.get(url)
            if response.status_code in (404, 400):
                # Set/Sprache nicht verfügbar - nicht retry-würdig
                response.raise_for_status()
            response.raise_for_status()
            return response.json()
    raise RuntimeError("unreachable")  # pragma: no cover


def _ensure_game(session: Session) -> uuid.UUID:
    game = session.execute(select(Game).where(Game.slug == GAME_SLUG)).scalar_one_or_none()
    if game:
        return game.id
    game = Game(slug=GAME_SLUG, name="Pokemon TCG")
    session.add(game)
    session.flush()
    return game.id


def _parse_release(raw: dict) -> date | None:
    s = raw.get("releaseDate")
    if not s:
        return None
    try:
        return date.fromisoformat(s.replace("/", "-"))
    except ValueError:
        return None


def _images(card_raw: dict) -> tuple[str | None, str | None]:
    image = card_raw.get("image")
    if not image:
        return None, None
    return f"{image}/low.webp", f"{image}/high.webp"


def _upsert_set(
    session: Session, game_id: uuid.UUID, lang: str, raw: dict
) -> uuid.UUID:
    release = _parse_release(raw)
    total = (raw.get("cardCount") or {}).get("total")
    symbol = raw.get("symbol")
    # TCGdex liefert Set-Namen ohne Sprachsuffix. Wir lassen das Original.
    stmt = (
        insert(CardSet)
        .values(
            id=uuid.uuid4(),
            game_id=game_id,
            code=raw["id"],
            name=raw["name"],
            language=lang,
            release_date=release,
            total_cards=total,
            symbol_asset_url=symbol,
        )
        .on_conflict_do_update(
            constraint="uq_card_sets_game_code_lang",
            set_={
                "name": raw["name"],
                "release_date": release,
                "total_cards": total,
                "symbol_asset_url": symbol,
            },
        )
        .returning(CardSet.id)
    )
    return session.execute(stmt).scalar_one()


def _upsert_card(
    session: Session,
    game_id: uuid.UUID,
    set_id: uuid.UUID,
    lang: str,
    raw: dict,
) -> None:
    img_small, img_large = _images(raw)
    name_loc = {lang: raw.get("name") or ""}
    stmt = (
        insert(Card)
        .values(
            id=uuid.uuid4(),
            game_id=game_id,
            set_id=set_id,
            number=str(raw["localId"]),
            name_localized=name_loc,
            image_url_small=img_small,
            image_url_large=img_large,
            external_id=raw.get("id"),
        )
        .on_conflict_do_update(
            constraint="uq_cards_set_number",
            set_={
                "name_localized": name_loc,
                "image_url_small": img_small,
                "image_url_large": img_large,
                "external_id": raw.get("id"),
            },
        )
    )
    session.execute(stmt)


async def _process_lang(
    client: httpx.AsyncClient,
    session: Session,
    game_id: uuid.UUID,
    lang: str,
    set_filter: set[str] | None,
    skip_no_image: bool,
    progress: Progress,
) -> tuple[int, int, int]:
    """Liefert (sets_processed, cards_imported, cards_skipped)."""
    try:
        sets_list = await _get_json(client, f"{TCGDEX_BASE}/{lang}/sets")
    except httpx.HTTPStatusError as exc:
        console.print(f"[red]Sprache {lang} nicht verfuegbar: {exc}[/red]")
        return 0, 0, 0
    assert isinstance(sets_list, list)

    if set_filter:
        sets_list = [s for s in sets_list if s["id"] in set_filter]

    task = progress.add_task(f"[cyan]{lang.upper()}", total=len(sets_list))
    cards_total = 0
    cards_skipped = 0
    sets_done = 0

    for set_meta in sets_list:
        try:
            detail = await _get_json(client, f"{TCGDEX_BASE}/{lang}/sets/{set_meta['id']}")
        except httpx.HTTPStatusError:
            progress.advance(task)
            continue
        assert isinstance(detail, dict)

        try:
            set_id = _upsert_set(session, game_id, lang, detail)
        except Exception as exc:  # noqa: BLE001
            session.rollback()
            console.print(
                f"[yellow]Set {lang}/{set_meta['id']} uebersprungen: {exc}[/yellow]"
            )
            progress.advance(task)
            continue

        for card_raw in detail.get("cards", []):
            if skip_no_image and not card_raw.get("image"):
                cards_skipped += 1
                continue
            try:
                _upsert_card(session, game_id, set_id, lang, card_raw)
                cards_total += 1
            except Exception as exc:  # noqa: BLE001
                session.rollback()
                console.print(
                    f"[yellow]Karte {card_raw.get('id')} uebersprungen: {exc}[/yellow]"
                )

        session.commit()
        sets_done += 1
        progress.update(
            task,
            advance=1,
            description=f"[cyan]{lang.upper()}[/cyan] {set_meta['id']} (+{cards_total} Karten)",
        )

    return sets_done, cards_total, cards_skipped


@app.command()
def main(
    languages: str = typer.Option(
        DEFAULT_LANGS, help="Komma-getrennt z.B. en,de,ja,fr,it,es,pt"
    ),
    sets: str | None = typer.Option(None, help="Nur diese TCGdex-Set-IDs (komma-getrennt)"),
    skip_no_image: bool = typer.Option(
        True, help="Karten ohne `image` ueberspringen (z.B. einige Promos)"
    ),
    concurrency: int = typer.Option(5, help="Parallele HTTP-Connections pro AsyncClient"),
) -> None:
    """Importiert Pokemon-Stammdaten + Bilder-URLs von TCGdex nach Postgres."""
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)

    langs = [item.strip() for item in languages.split(",") if item.strip()]
    set_filter = (
        {item.strip() for item in sets.split(",") if item.strip()} if sets else None
    )
    limits = httpx.Limits(
        max_connections=concurrency, max_keepalive_connections=concurrency
    )

    async def runner() -> tuple[int, int, int]:
        total_sets = total_cards = total_skipped = 0
        async with httpx.AsyncClient(timeout=30.0, limits=limits) as client:
            with Session(engine) as session:
                game_id = _ensure_game(session)
                session.commit()
                with Progress(
                    SpinnerColumn(),
                    TextColumn("[progress.description]{task.description}"),
                    BarColumn(),
                    MofNCompleteColumn(),
                    console=console,
                    transient=False,
                ) as progress:
                    for lang in langs:
                        s_count, c_count, skipped = await _process_lang(
                            client,
                            session,
                            game_id,
                            lang,
                            set_filter,
                            skip_no_image,
                            progress,
                        )
                        total_sets += s_count
                        total_cards += c_count
                        total_skipped += skipped
        return total_sets, total_cards, total_skipped

    sets_n, cards_n, skipped_n = asyncio.run(runner())
    console.print(
        f"[green]Fertig:[/green] {sets_n} Sets, {cards_n} Karten importiert, "
        f"{skipped_n} ohne Bild uebersprungen."
    )


if __name__ == "__main__":
    app()
