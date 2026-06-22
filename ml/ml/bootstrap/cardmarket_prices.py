"""Bridge: Cardmarket-Preise von pokemontcg.io in die Postgres.

Verwendung:
    uv run python -m ml.bootstrap.cardmarket_prices
    uv run python -m ml.bootstrap.cardmarket_prices --languages en,de --limit-sets 5

Architektur:
- pokemontcg.io liefert pro Karte einen `cardmarket.prices`-Block mit
  averageSellPrice, lowPrice, trendPrice (EUR) und separat Reverse-Holo-Felder.
- TCGdex und pokemontcg.io haben unterschiedliche Set-IDs (`sv03.5` vs `sv3pt5`)
  und Number-Konventionen (`004` vs `4`). Matching ueber (set_name, total_cards)
  fuer Sets und ueber int-normalisierte Card-Number innerhalb des Sets.
- Pro Karte koennen bis zu zwei Variants entstehen:
    * (language, edition='unlimited', finish='normal')
    * (language, edition='unlimited', finish='reverse_holo') falls Reverse-Daten existieren
- Eine `Price`-Row pro (variant, source='cardmarket', condition='NM').
"""
from __future__ import annotations

import sys
import uuid
from datetime import UTC, datetime
from decimal import Decimal

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
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from ml.config import get_settings

try:
    from app.infra.models import Card, CardSet, CardVariant, Game, Price  # type: ignore[import-not-found]
except ImportError:
    sys.stderr.write(
        "Backend-Modelle nicht importierbar. Setze PYTHONPATH:\n"
        '  $env:PYTHONPATH = "../backend"\n'
    )
    raise

POKEMONTCG_BASE = "https://api.pokemontcg.io/v2"
GAME_SLUG = "pokemon"
SOURCE = "cardmarket"

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


def _client(api_key: str | None) -> httpx.Client:
    headers = {"X-Api-Key": api_key} if api_key else {}
    return httpx.Client(base_url=POKEMONTCG_BASE, headers=headers, timeout=30.0)


@retry(
    stop=stop_after_attempt(5),
    wait=wait_exponential(min=1, max=20),
    retry=retry_if_exception_type((httpx.TransportError, httpx.HTTPStatusError, httpx.TimeoutException)),
    reraise=True,
)
def _get(client: httpx.Client, path: str, params: dict | None = None) -> dict:
    response = client.get(path, params=params)
    response.raise_for_status()
    return response.json()


def _norm_number(value: str) -> str:
    """`004` -> `4`, aber `TG01` bleibt."""
    try:
        return str(int(value))
    except (ValueError, TypeError):
        return str(value)


def _eur(value: object) -> Decimal | None:
    if value in (None, 0, 0.0):
        return None
    try:
        return Decimal(str(value)).quantize(Decimal("0.01"))
    except (ArithmeticError, ValueError):
        return None


def _upsert_variant(
    session: Session, card_id: uuid.UUID, language: str, finish: str
) -> uuid.UUID:
    stmt = (
        insert(CardVariant)
        .values(
            id=uuid.uuid4(),
            card_id=card_id,
            language=language,
            edition="unlimited",
            finish=finish,
        )
        .on_conflict_do_update(
            constraint="uq_card_variants_identity",
            set_={"finish": finish},  # no-op update damit RETURNING liefert
        )
        .returning(CardVariant.id)
    )
    return session.execute(stmt).scalar_one()


def _insert_price(
    session: Session,
    variant_id: uuid.UUID,
    price_eur: Decimal,
    trend_eur: Decimal | None,
    fetched_at: datetime,
) -> None:
    session.add(
        Price(
            id=uuid.uuid4(),
            variant_id=variant_id,
            source=SOURCE,
            condition="NM",
            price_eur=price_eur,
            trend_7d_eur=trend_eur,
            fetched_at=fetched_at,
        )
    )


def _parse_fetched_at(raw: str | None) -> datetime:
    if not raw:
        return datetime.now(tz=UTC)
    try:
        return datetime.strptime(raw, "%Y/%m/%d").replace(tzinfo=UTC)
    except ValueError:
        return datetime.now(tz=UTC)


def _match_db_sets_by_name(
    session: Session, ptcg_set: dict, languages: list[str]
) -> list[CardSet]:
    """Findet DB-Sets mit gleichem Namen oder via uebliche Aliase pro Sprache."""
    name = ptcg_set["name"].strip()
    total = ptcg_set.get("total")

    stmt = (
        select(CardSet)
        .join(Game, Game.id == CardSet.game_id)
        .where(Game.slug == GAME_SLUG)
        .where(CardSet.language.in_(languages))
    )
    candidates = session.execute(stmt).scalars().all()

    # Bevorzugt exakter Name + total_cards-Match
    matches = [
        c for c in candidates if c.name.strip().lower() == name.lower() and c.total_cards == total
    ]
    if matches:
        return matches

    # Fallback: total_cards Match (Set wurde lokalisiert umbenannt)
    return [c for c in candidates if c.total_cards == total]


def _process_set(
    session: Session,
    http: httpx.Client,
    ptcg_set: dict,
    db_sets: list[CardSet],
    languages: list[str],
) -> tuple[int, int]:
    """Liefert (variants_upserted, prices_inserted)."""
    page = 1
    cards_by_num: dict[str, dict] = {}
    while True:
        payload = _get(
            http,
            "/cards",
            params={"q": f"set.id:{ptcg_set['id']}", "page": page, "pageSize": 250},
        )
        page_cards = payload.get("data") or []
        if not page_cards:
            break
        for raw in page_cards:
            cards_by_num[_norm_number(raw["number"])] = raw
        if len(page_cards) < 250:
            break
        page += 1

    if not cards_by_num:
        return 0, 0

    # DB-Karten pro language-Set holen, gemappt auf normalisierte number
    variants_n = prices_n = 0

    for db_set in db_sets:
        if db_set.language not in languages:
            continue
        db_cards_stmt = select(Card).where(Card.set_id == db_set.id)
        db_cards = session.execute(db_cards_stmt).scalars().all()
        for db_card in db_cards:
            ptcg = cards_by_num.get(_norm_number(db_card.number))
            if not ptcg:
                continue
            cm = (ptcg.get("cardmarket") or {})
            prices = cm.get("prices") or {}
            fetched_at = _parse_fetched_at(cm.get("updatedAt"))

            normal_avg = _eur(prices.get("averageSellPrice"))
            normal_trend = _eur(prices.get("avg7"))
            if normal_avg is not None:
                vid = _upsert_variant(session, db_card.id, db_set.language, "normal")
                _insert_price(session, vid, normal_avg, normal_trend, fetched_at)
                variants_n += 1
                prices_n += 1

            rh_avg = _eur(prices.get("reverseHoloSell"))
            rh_trend = _eur(prices.get("reverseHoloAvg7"))
            if rh_avg is not None:
                vid = _upsert_variant(session, db_card.id, db_set.language, "reverse_holo")
                _insert_price(session, vid, rh_avg, rh_trend, fetched_at)
                variants_n += 1
                prices_n += 1

    return variants_n, prices_n


@app.command()
def main(
    languages: str = typer.Option("en,de", help="Sprachen die Preise erhalten sollen"),
    limit_sets: int = typer.Option(0, help="Maximal so viele pokemontcg.io-Sets (0=alle)"),
    only_ptcg_sets: str | None = typer.Option(
        None, help="Komma-getrennte pokemontcg.io-Set-IDs (z.B. sv3pt5,base1)"
    ),
) -> None:
    """Cardmarket-Preise via pokemontcg.io in card_variants/prices laden."""
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)
    lang_list = [item.strip() for item in languages.split(",") if item.strip()]
    only_filter = (
        {item.strip() for item in only_ptcg_sets.split(",") if item.strip()}
        if only_ptcg_sets
        else None
    )

    with _client(settings.pokemontcg_api_key) as http, Session(engine) as session:
        sets_payload = _get(http, "/sets", params={"pageSize": 250})
        sets = sets_payload.get("data") or []
        if only_filter:
            sets = [s for s in sets if s["id"] in only_filter]
        if limit_sets:
            sets = sets[:limit_sets]

        console.print(f"[bold]{len(sets)}[/bold] pokemontcg.io-Sets zu verarbeiten.")
        total_variants = total_prices = matched_sets = skipped_sets = 0

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            console=console,
        ) as bar:
            task = bar.add_task("Bridging", total=len(sets))
            for ptcg_set in sets:
                db_sets = _match_db_sets_by_name(session, ptcg_set, lang_list)
                if not db_sets:
                    skipped_sets += 1
                    bar.update(
                        task,
                        advance=1,
                        description=f"[yellow]skip[/yellow] {ptcg_set['id']} (kein DB-Match)",
                    )
                    continue
                try:
                    v_n, p_n = _process_set(session, http, ptcg_set, db_sets, lang_list)
                    session.commit()
                    total_variants += v_n
                    total_prices += p_n
                    matched_sets += 1
                except Exception as exc:  # noqa: BLE001
                    session.rollback()
                    console.print(
                        f"[red]Fehler bei {ptcg_set['id']}: {exc}[/red]"
                    )
                bar.update(
                    task,
                    advance=1,
                    description=f"{ptcg_set['id']} (+{total_prices} Preise)",
                )

        console.print(
            f"[green]Fertig:[/green] {matched_sets} Sets gematcht, "
            f"{skipped_sets} ohne DB-Match, {total_variants} Variants, "
            f"{total_prices} Preis-Rows."
        )


if __name__ == "__main__":
    app()
