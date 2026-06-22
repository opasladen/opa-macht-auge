"""Cardmarket-Produkt-Katalog -> cardmarket_expansion_id / cardmarket_product_id.

Cardmarket bietet keine oeffentliche API, aber unter
https://downloads.s3.cardmarket.com/productCatalog/productList/
liegen aktuelle JSON-Snapshots pro TCG-Spiel. Wir laden den Pokemon-Singles-
Snapshot (Game-ID 6) und mappen ihn heuristisch gegen unsere DB:

  1. Set-Match: Pro DB-CardSet finde die Cardmarket-`idExpansion` mit der
     groessten Schnittmenge an Pokemon-Namen. Score = |intersect| / |db_cards|.
     Schwellwert >=0.5 = robuster Treffer.
  2. Card-Match: Innerhalb einer gemappten idExpansion: pro DB-Karte normalisiere
     den Pokemon-Namen (alles vor `[`) und versuche einen eindeutigen Match
     auf einen Cardmarket-Eintrag. Mehrdeutige Matches bleiben unverknuepft.

Aufruf:
    uv run python -m ml.bootstrap.cardmarket_catalog refresh
    uv run python -m ml.bootstrap.cardmarket_catalog download
    uv run python -m ml.bootstrap.cardmarket_catalog match --languages en,de
    uv run python -m ml.bootstrap.cardmarket_catalog report

Idempotent: kann beliebig oft laufen. Bestehende IDs werden ueberschrieben
falls sich der Heuristik-Treffer aendert (z. B. weil Cardmarket einer
Expansion mehr Karten hinzugefuegt hat).
"""
from __future__ import annotations

import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

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
from rich.table import Table
from sqlalchemy import create_engine, func, select, text, update
from sqlalchemy.orm import Session
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from ml.config import get_settings

try:
    from app.infra.models import Card, CardSet, Game  # type: ignore[import-not-found]
except ImportError:
    sys.stderr.write(
        "Backend-Modelle nicht importierbar. Setze PYTHONPATH:\n"
        '  $env:PYTHONPATH = "../backend"\n'
    )
    raise

GAME_SLUG = "pokemon"
# Cardmarket-Game-IDs siehe https://www.cardmarket.com/en/Magic/Data/Product-List
CATALOG_URLS: dict[str, str] = {
    "pokemon": "https://downloads.s3.cardmarket.com/productCatalog/productList/products_singles_6.json",
}
DATA_DIR = Path(__file__).resolve().parents[2] / "data" / "cardmarket"
SET_MATCH_MIN_SCORE = 0.5
SET_MATCH_MIN_CARDS = 5

app = typer.Typer(add_completion=False, no_args_is_help=True)
console = Console()


# ---------- Name-Normalisierung -----------------------------------------------

_BRACKET_RE = re.compile(r"\s*[\[(].*?[\])]\s*")
_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")


def _norm_name(raw: str) -> str:
    """ASCII-fold, lowercase, alles in eckigen Klammern raus, dann nur a-z0-9."""
    folded = unicodedata.normalize("NFKD", raw)
    folded = "".join(c for c in folded if not unicodedata.combining(c))
    stripped = _BRACKET_RE.sub(" ", folded.lower())
    return _NON_ALNUM_RE.sub("", stripped)


# ---------- Download ----------------------------------------------------------

@retry(
    stop=stop_after_attempt(5),
    wait=wait_exponential(min=2, max=30),
    retry=retry_if_exception_type((httpx.TransportError, httpx.HTTPStatusError, httpx.TimeoutException)),
    reraise=True,
)
def _download(url: str, dest: Path) -> int:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with httpx.Client(timeout=120.0, follow_redirects=True) as client, dest.open("wb") as fh:
        with client.stream("GET", url) as resp:
            resp.raise_for_status()
            total = 0
            for chunk in resp.iter_bytes(chunk_size=65536):
                fh.write(chunk)
                total += len(chunk)
    return total


@app.command()
def download(
    game: str = typer.Option(GAME_SLUG, help="Game-Slug (z. Z. nur 'pokemon')"),
) -> None:
    """Laedt den aktuellen Cardmarket-Singles-Katalog runter."""
    if game not in CATALOG_URLS:
        raise typer.BadParameter(f"Unbekanntes Game: {game}")
    dest = DATA_DIR / f"products_singles_{game}.json"
    console.print(f"Download {CATALOG_URLS[game]} -> {dest}")
    size = _download(CATALOG_URLS[game], dest)
    console.print(f"[green]{size / 1024 / 1024:.1f} MB[/green] gespeichert.")


# ---------- Matching ----------------------------------------------------------

def _load_catalog(game: str) -> list[dict]:
    path = DATA_DIR / f"products_singles_{game}.json"
    if not path.exists():
        raise typer.BadParameter(
            f"Katalog fehlt: {path}. Erst `download` ausfuehren."
        )
    with path.open("r", encoding="utf-8") as fh:
        payload = json.load(fh)
    products = payload.get("products") or []
    console.print(f"Katalog geladen: {len(products)} Produkte aus {path.name}")
    return products


def _index_catalog(products: list[dict]) -> dict[int, list[dict]]:
    by_expansion: dict[int, list[dict]] = defaultdict(list)
    for product in products:
        ex_id = product.get("idExpansion")
        if ex_id is None:
            continue
        by_expansion[int(ex_id)].append(product)
    return by_expansion


def _expansion_name_index(
    by_expansion: dict[int, list[dict]],
) -> dict[int, Counter[str]]:
    """idExpansion -> Counter normalisierter Karten-Namen (ohne Brackets)."""
    return {
        ex_id: Counter(_norm_name(p["name"]) for p in products if p.get("name"))
        for ex_id, products in by_expansion.items()
    }


def _db_card_names(session: Session, set_id) -> list[tuple[str, str]]:
    """Liefert (db_card.id, normalisierter Name) pro Karte.

    Cardmarket fuehrt im Snapshot ausschliesslich englische Karten-Namen,
    deshalb matchen wir immer gegen `name_localized['en']` — fuer DE/JA-Sets
    waere die lokalisierte Bezeichnung gar nicht im Katalog auffindbar.
    """
    rows = session.execute(
        select(Card.id, Card.name_localized)
        .where(Card.set_id == set_id)
    ).all()
    out: list[tuple[str, str]] = []
    for row in rows:
        names = row.name_localized or {}
        raw = names.get("en") or next(iter(names.values()), "")
        if raw:
            out.append((row.id, _norm_name(raw)))
    return out


def _match_sets(
    session: Session,
    by_expansion: dict[int, list[dict]],
    expansion_names: dict[int, Counter[str]],
    languages: list[str],
) -> dict:
    """Mappt CardSet -> idExpansion."""
    sets = session.execute(
        select(CardSet)
        .join(Game, Game.id == CardSet.game_id)
        .where(Game.slug == GAME_SLUG)
        .where(CardSet.language.in_(languages))
    ).scalars().all()

    stats = {"total": len(sets), "matched": 0, "skipped": 0, "low_score": 0}
    matched_ids: dict = {}

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        console=console,
    ) as bar:
        task = bar.add_task("Sets matchen", total=len(sets))
        for db_set in sets:
            db_cards = _db_card_names(session, db_set.id)
            if len(db_cards) < SET_MATCH_MIN_CARDS:
                stats["skipped"] += 1
                bar.update(task, advance=1)
                continue
            db_name_set = {n for _, n in db_cards if n}

            best_ex: int | None = None
            best_score = 0.0
            for ex_id, cm_names in expansion_names.items():
                overlap = sum(1 for n in db_name_set if cm_names.get(n))
                score = overlap / max(1, len(db_name_set))
                if score > best_score:
                    best_score = score
                    best_ex = ex_id

            if best_ex is not None and best_score >= SET_MATCH_MIN_SCORE:
                db_set.cardmarket_expansion_id = best_ex
                matched_ids[db_set.id] = best_ex
                stats["matched"] += 1
                bar.update(
                    task,
                    advance=1,
                    description=f"{db_set.code}/{db_set.language} → {best_ex} ({best_score:.0%})",
                )
            else:
                stats["low_score"] += 1
                bar.update(
                    task,
                    advance=1,
                    description=f"[yellow]{db_set.code}/{db_set.language} ungemappt[/yellow]",
                )

        session.commit()

    return {"stats": stats, "matched_ids": matched_ids}


def _match_cards(
    session: Session,
    by_expansion: dict[int, list[dict]],
) -> dict:
    """Pro Set mit cardmarket_expansion_id: mappe Karten -> idMetacard (+idProduct).

    Strategie:
      - Im Expansion-Bucket gruppieren wir nach normalisiertem Namen.
      - Pro Name sammeln wir die distinct idMetacards. Wenn nur EINE idMetacard
        existiert -> eindeutig, wir setzen `cardmarket_metacard_id`.
      - Hat diese idMetacard zudem nur EIN idProduct in der Expansion,
        ist auch die sprach-spezifische `cardmarket_product_id` eindeutig.
      - Mehrere idMetacards mit gleichem Namen -> mehrdeutig (z. B. Standard
        + SAR + Promo derselben Karte), beide IDs bleiben NULL.
    """
    sets_with_ex = session.execute(
        select(CardSet)
        .join(Game, Game.id == CardSet.game_id)
        .where(Game.slug == GAME_SLUG)
        .where(CardSet.cardmarket_expansion_id.is_not(None))
    ).scalars().all()

    stats = {
        "total_cards": 0,
        "metacard_matched": 0,
        "product_matched": 0,
        "ambiguous_metacard": 0,
        "no_match": 0,
    }

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        console=console,
    ) as bar:
        task = bar.add_task("Karten matchen", total=len(sets_with_ex))
        for db_set in sets_with_ex:
            ex_id = db_set.cardmarket_expansion_id
            cm_products = by_expansion.get(ex_id, [])
            if not cm_products:
                bar.update(task, advance=1)
                continue

            # norm_name -> dict[idMetacard -> list[idProduct]]
            cm_bucket: dict[str, dict[int, list[int]]] = defaultdict(
                lambda: defaultdict(list)
            )
            for prod in cm_products:
                key = _norm_name(prod["name"])
                meta_id = int(prod["idMetacard"])
                cm_bucket[key][meta_id].append(int(prod["idProduct"]))

            db_cards = session.execute(
                select(Card).where(Card.set_id == db_set.id)
            ).scalars().all()

            # DB-seitig pro normalisiertem Namen zaehlen. Wenn ein Set
            # mehrere Drucke derselben Karte enthaelt (z. B. Standard +
            # Special Art Rare) waehrend Cardmarket diese unter einer
            # einzigen idMetacard fuehrt, bleibt das Mapping mehrdeutig.
            db_counts: Counter[str] = Counter()
            for card in db_cards:
                names = card.name_localized or {}
                raw = names.get("en") or next(iter(names.values()), "")
                if raw:
                    db_counts[_norm_name(raw)] += 1

            for card in db_cards:
                stats["total_cards"] += 1
                names = card.name_localized or {}
                raw = names.get("en") or next(iter(names.values()), "")
                if not raw:
                    stats["no_match"] += 1
                    continue
                key = _norm_name(raw)
                meta_bucket = cm_bucket.get(key)
                if not meta_bucket:
                    stats["no_match"] += 1
                    continue
                if len(meta_bucket) > 1:
                    stats["ambiguous_metacard"] += 1
                    continue
                if db_counts[key] > 1:
                    # Mehrere DB-Drucke teilen sich denselben Namen, CM hat
                    # nur eine Metacard -> wir wissen nicht welcher Druck
                    # gemeint ist, also nicht zuordnen.
                    stats["ambiguous_metacard"] += 1
                    continue
                # Genau eine idMetacard - sprach-agnostische Karte gefunden.
                meta_id, product_ids = next(iter(meta_bucket.items()))
                card.cardmarket_metacard_id = meta_id
                stats["metacard_matched"] += 1
                if len(product_ids) == 1:
                    card.cardmarket_product_id = product_ids[0]
                    stats["product_matched"] += 1

            bar.update(task, advance=1)

        session.commit()

    return stats


def _propagate_to_other_languages(session: Session) -> dict:
    """Cardmarket-IDs sind sprach-agnostisch.

    Wir matchen primaer gegen EN-Karten (CM-Snapshot enthaelt nur EN-Namen)
    und propagieren idMetacard + idExpansion auf die Karten/Sets anderer
    Sprachen ueber (set.code, card.number). Dadurch bekommen DE- und JA-Sets
    die gleichen Cardmarket-Identitaeten wie ihre EN-Pendants.

    idProduct propagieren wir bewusst NICHT, weil das sprach-spezifisch
    waere und das Snapshot uns die Sprach-Zuordnung pro idProduct nicht
    liefert.
    """
    # Set-Propagation: alle Sets mit gleicher code aber ohne expansion_id
    set_sql = """
        UPDATE card_sets target
        SET cardmarket_expansion_id = source.cardmarket_expansion_id
        FROM card_sets source
        WHERE target.cardmarket_expansion_id IS NULL
          AND source.cardmarket_expansion_id IS NOT NULL
          AND target.code = source.code
          AND target.game_id = source.game_id
          AND target.id <> source.id
    """
    set_result = session.execute(text(set_sql))

    # Card-Propagation ueber (set.code, card.number) - idMetacard ist
    # sprach-agnostisch, daher unbedenklich.
    card_sql = """
        UPDATE cards AS target
        SET cardmarket_metacard_id = src.metacard_id
        FROM (
            SELECT cs.code AS set_code,
                   cs.game_id AS game_id,
                   c.number AS number,
                   c.cardmarket_metacard_id AS metacard_id
            FROM cards c
            JOIN card_sets cs ON cs.id = c.set_id
            WHERE c.cardmarket_metacard_id IS NOT NULL
        ) AS src
        WHERE target.cardmarket_metacard_id IS NULL
          AND target.number = src.number
          AND target.set_id IN (
              SELECT id FROM card_sets
              WHERE code = src.set_code AND game_id = src.game_id
          )
    """
    card_result = session.execute(text(card_sql))
    session.commit()
    return {
        "sets_propagated": set_result.rowcount or 0,
        "cards_propagated": card_result.rowcount or 0,
    }

@app.command()
def match(
    languages: str = typer.Option("en,de,ja", help="Set-Sprachen die gemappt werden"),
    game: str = typer.Option(GAME_SLUG, help="Game-Slug"),
) -> None:
    """Laeuft Set- und Karten-Matching gegen den letzten Katalog-Snapshot."""
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)
    lang_list = [item.strip() for item in languages.split(",") if item.strip()]

    products = _load_catalog(game)
    by_expansion = _index_catalog(products)
    expansion_names = _expansion_name_index(by_expansion)

    with Session(engine) as session:
        console.print("[bold]Schritt 1/2:[/bold] Set-Match")
        set_result = _match_sets(session, by_expansion, expansion_names, lang_list)
        s = set_result["stats"]
        console.print(
            f"Sets: {s['matched']}/{s['total']} gemappt, "
            f"{s['low_score']} unter Schwellwert, {s['skipped']} ueberprungen.\n"
        )

        console.print("[bold]Schritt 2/2:[/bold] Card-Match")
        card_stats = _match_cards(session, by_expansion)
        c = card_stats
        meta_rate = c["metacard_matched"] / max(1, c["total_cards"])
        prod_rate = c["product_matched"] / max(1, c["total_cards"])
        console.print(
            f"Karten: metacard {c['metacard_matched']}/{c['total_cards']} ({meta_rate:.1%}), "
            f"product {c['product_matched']}/{c['total_cards']} ({prod_rate:.1%}), "
            f"{c['ambiguous_metacard']} mehrdeutig, {c['no_match']} ohne Match.\n"
        )

        console.print("[bold]Schritt 3/3:[/bold] Propagation auf andere Sprachen")
        prop = _propagate_to_other_languages(session)
        console.print(
            f"Propagiert: {prop['sets_propagated']} Sets, "
            f"{prop['cards_propagated']} Karten.\n"
        )

    console.print("[green]Done.[/green]")


@app.command()
def report() -> None:
    """Match-Quality-Report pro Set."""
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)
    with Session(engine) as session:
        # Sets-Coverage
        sets_total = session.execute(
            select(func.count()).select_from(CardSet)
            .join(Game, Game.id == CardSet.game_id)
            .where(Game.slug == GAME_SLUG)
        ).scalar_one()
        sets_matched = session.execute(
            select(func.count()).select_from(CardSet)
            .join(Game, Game.id == CardSet.game_id)
            .where(Game.slug == GAME_SLUG)
            .where(CardSet.cardmarket_expansion_id.is_not(None))
        ).scalar_one()

        # Cards-Coverage
        cards_total = session.execute(
            select(func.count()).select_from(Card)
            .join(Game, Game.id == Card.game_id)
            .where(Game.slug == GAME_SLUG)
        ).scalar_one()
        cards_metacard = session.execute(
            select(func.count()).select_from(Card)
            .join(Game, Game.id == Card.game_id)
            .where(Game.slug == GAME_SLUG)
            .where(Card.cardmarket_metacard_id.is_not(None))
        ).scalar_one()
        cards_product = session.execute(
            select(func.count()).select_from(Card)
            .join(Game, Game.id == Card.game_id)
            .where(Game.slug == GAME_SLUG)
            .where(Card.cardmarket_product_id.is_not(None))
        ).scalar_one()

        table = Table(title="Cardmarket-Match-Coverage")
        table.add_column("Scope")
        table.add_column("Matched", justify="right")
        table.add_column("Total", justify="right")
        table.add_column("%", justify="right")
        table.add_row("Sets", str(sets_matched), str(sets_total),
                      f"{sets_matched / max(1, sets_total):.1%}")
        table.add_row("Cards (metacard)", str(cards_metacard), str(cards_total),
                      f"{cards_metacard / max(1, cards_total):.1%}")
        table.add_row("Cards (product)", str(cards_product), str(cards_total),
                      f"{cards_product / max(1, cards_total):.1%}")
        console.print(table)

        # Top-Sets ohne Match
        unmatched = session.execute(
            select(CardSet.code, CardSet.language, CardSet.name, CardSet.total_cards)
            .join(Game, Game.id == CardSet.game_id)
            .where(Game.slug == GAME_SLUG)
            .where(CardSet.cardmarket_expansion_id.is_(None))
            .order_by(CardSet.total_cards.desc().nullslast())
            .limit(20)
        ).all()
        if unmatched:
            t2 = Table(title="Top-20 ungemappte Sets")
            t2.add_column("Code")
            t2.add_column("Lang")
            t2.add_column("Name")
            t2.add_column("Karten", justify="right")
            for row in unmatched:
                t2.add_row(row.code, row.language, row.name, str(row.total_cards or "-"))
            console.print(t2)


@app.command()
def refresh(
    languages: str = typer.Option("en,de,ja"),
    game: str = typer.Option(GAME_SLUG),
) -> None:
    """Download + Match in einem Schritt (fuer Cron/Justfile)."""
    download(game=game)
    match(languages=languages, game=game)
    report()


@app.command()
def clear(
    yes: bool = typer.Option(False, "--yes", "-y", help="Bestaetigung"),
) -> None:
    """Setzt alle cardmarket_*_id-Spalten auf NULL (z. B. fuer Re-Run)."""
    if not yes:
        raise typer.BadParameter("Bitte mit --yes bestaetigen.")
    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)
    with Session(engine) as session:
        session.execute(update(Card).values(
            cardmarket_product_id=None,
            cardmarket_metacard_id=None,
        ))
        session.execute(update(CardSet).values(cardmarket_expansion_id=None))
        session.commit()
    console.print("[green]Geleert.[/green]")


if __name__ == "__main__":
    app()
