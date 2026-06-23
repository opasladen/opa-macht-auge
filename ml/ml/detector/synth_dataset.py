"""Synthetisches Trainingsdaten-Set fuer YOLO11n OBB-Detector.

Pipeline:
    1. Aus DB random Cards mit image_url_small sampeln.
    2. Bilder einmalig lokal cachen (datasets/.card_cache/{card_id}.webp).
    3. Pro Output-Sample:
       - Procedural Background (oder aus --backgrounds-dir gepickt).
       - 1..max_cards Karten via Perspective-Warp + Rotation + Scale platzieren.
       - Color-Jitter + Gauss-Noise + leichte Verdeckungen.
       - 4-Eckpunkte (OBB) tracken, in Bild-Koordinaten transformieren.
    4. Schreibe Bild als JPG + Label im YOLO-OBB-Format (normalisiert, 1 Klasse 'card').

Aufruf:
    $env:PYTHONPATH = "..\\backend"
    uv run --group train python -m ml.detector.synth_dataset \\
        --num-train 8000 --num-val 1000 \\
        --output-dir datasets/cards_obb --img-size 1280 --max-cards 9

YOLO-OBB-Format (eine Zeile pro Karte):
    <cls> <x1> <y1> <x2> <y2> <x3> <y3> <x4> <y4>
Alle Koordinaten normalisiert auf [0,1].
"""
from __future__ import annotations

import asyncio
import io
import random
import sys
import uuid
from collections.abc import Iterable
from pathlib import Path

import cv2
import httpx
import numpy as np
import typer
from PIL import Image, ImageEnhance, ImageFilter
from rich.console import Console
from rich.progress import (
    BarColumn,
    Progress,
    TextColumn,
    TimeElapsedColumn,
    TimeRemainingColumn,
)
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import Session

from ml.config import get_settings

try:
    from app.infra.models import Card  # type: ignore[import-not-found]
except ImportError:
    sys.stderr.write(
        "Backend-Modelle nicht importierbar. Setze PYTHONPATH:\n"
        '  $env:PYTHONPATH = "..\\backend"\n'
    )
    raise

app = typer.Typer(add_completion=False, no_args_is_help=False)
console = Console()


# ---------------------------------------------------------------------------
# 1. DB-Sample + Card-Cache
# ---------------------------------------------------------------------------

async def _fetch_image(
    client: httpx.AsyncClient, url: str, dest: Path
) -> Path | None:
    if dest.exists() and dest.stat().st_size > 1024:
        return dest
    try:
        resp = await client.get(url)
        resp.raise_for_status()
        dest.write_bytes(resp.content)
        return dest
    except Exception as exc:  # noqa: BLE001
        console.print(f"[red]Bild-Fehler {url}: {exc}[/red]")
        return None


async def _cache_cards(
    rows: list[tuple[uuid.UUID, str]],
    cache_dir: Path,
    concurrency: int,
) -> list[Path]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    limits = httpx.Limits(
        max_connections=concurrency, max_keepalive_connections=concurrency
    )
    paths: list[Path] = []
    async with httpx.AsyncClient(timeout=30.0, limits=limits) as http:
        sem = asyncio.Semaphore(concurrency)

        async def worker(card_id: uuid.UUID, url: str) -> Path | None:
            ext = Path(url).suffix or ".webp"
            dest = cache_dir / f"{card_id}{ext}"
            async with sem:
                return await _fetch_image(http, url, dest)

        with Progress(
            TextColumn("[progress.description]{task.description}"),
            BarColumn(),
            TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
            TimeElapsedColumn(),
            TimeRemainingColumn(),
            console=console,
        ) as prog:
            tid = prog.add_task("Card-Cache fuellen", total=len(rows))
            tasks = [asyncio.create_task(worker(cid, url)) for cid, url in rows]
            for fut in asyncio.as_completed(tasks):
                res = await fut
                if res is not None:
                    paths.append(res)
                prog.advance(tid)
    return paths


def _sample_cards(session: Session, n: int) -> list[tuple[uuid.UUID, str]]:
    stmt = (
        select(Card.id, Card.image_url_small)
        .where(Card.image_url_small.is_not(None))
        .order_by(func.random())
        .limit(n)
    )
    return [(r[0], r[1]) for r in session.execute(stmt).all()]


# ---------------------------------------------------------------------------
# 2. Procedural Backgrounds
# ---------------------------------------------------------------------------

def _procedural_background(size: int, rng: random.Random) -> np.ndarray:
    """Erzeugt einen synthetischen Background (HWC uint8, RGB).

    Mischt: Solid Color, Gauss-Noise, leichte Texture-Linien (Holz/Stoff-Approx).
    """
    style = rng.choice(["solid", "noise", "wood", "fabric", "gradient"])
    base_h = rng.randint(0, 359)
    base_s = rng.randint(0, 80)
    base_v = rng.randint(100, 220)
    base_hsv = np.full((size, size, 3), [base_h, base_s, base_v], dtype=np.uint8)
    bg = cv2.cvtColor(base_hsv, cv2.COLOR_HSV2RGB)

    if style == "noise":
        noise = rng.randint(8, 30)
        n = np.random.normal(0, noise, (size, size, 3))
        bg = np.clip(bg.astype(np.int16) + n, 0, 255).astype(np.uint8)
    elif style == "wood":
        # Horizontale Streifen-Approximation
        stripes = np.zeros((size, size, 3), dtype=np.int16)
        period = rng.randint(20, 80)
        for y in range(0, size, period):
            stripe_color = rng.randint(-25, 25)
            stripes[y : y + period // 2] = stripe_color
        bg = np.clip(bg.astype(np.int16) + stripes, 0, 255).astype(np.uint8)
    elif style == "fabric":
        n = np.random.normal(0, 18, (size, size, 3))
        bg = np.clip(bg.astype(np.int16) + n, 0, 255).astype(np.uint8)
        kernel = np.ones((3, 3), np.float32) / 9
        bg = cv2.filter2D(bg, -1, kernel)
    elif style == "gradient":
        grad = np.linspace(-40, 40, size).astype(np.int16)
        if rng.random() < 0.5:
            grad = grad[:, None]
        else:
            grad = grad[None, :]
        bg = np.clip(bg.astype(np.int16) + grad[..., None], 0, 255).astype(np.uint8)

    return bg


def _load_external_bgs(folder: Path | None) -> list[Path]:
    if folder is None or not folder.exists():
        return []
    exts = {".jpg", ".jpeg", ".png", ".webp"}
    return [p for p in folder.iterdir() if p.suffix.lower() in exts]


def _pick_background(
    size: int,
    rng: random.Random,
    external_bgs: list[Path],
) -> np.ndarray:
    if external_bgs and rng.random() < 0.6:
        path = rng.choice(external_bgs)
        try:
            img = Image.open(path).convert("RGB")
            # Random Crop + Resize auf size x size
            w, h = img.size
            short = min(w, h)
            x = rng.randint(0, w - short)
            y = rng.randint(0, h - short)
            img = img.crop((x, y, x + short, y + short)).resize(
                (size, size), Image.BICUBIC
            )
            return np.array(img)
        except Exception as exc:  # noqa: BLE001
            console.print(f"[yellow]Background-Load-Fehler {path}: {exc}[/yellow]")
    return _procedural_background(size, rng)


# ---------------------------------------------------------------------------
# 3. Card-Composition mit Perspective + OBB-Tracking
# ---------------------------------------------------------------------------

def _load_card_rgba(path: Path) -> np.ndarray | None:
    try:
        img = Image.open(path).convert("RGBA")
        return np.array(img)
    except Exception:
        return None


def _warp_card(
    card: np.ndarray,
    target_size: int,
    rng: random.Random,
    max_perspective: float = 0.12,
    rotation_deg: float = 180.0,
    scale_range: tuple[float, float] = (0.12, 0.42),
) -> tuple[np.ndarray, np.ndarray]:
    """Wendet Perspective + Rotation + Scale auf Card-RGBA an.

    Returnt:
        warped: HxWx4 uint8 RGBA, gleiche Groesse wie target (target_size, target_size)
        polygon: 4x2 float32, Eckpunkte (TL, TR, BR, BL) in Pixel-Koordinaten auf target.
    """
    ch, cw = card.shape[:2]

    # 1. Skalieren: Karten-Hoehe relativ zur Ziel-Bildgroesse
    scale = rng.uniform(*scale_range)
    new_h = int(target_size * scale)
    new_w = int(new_h * cw / ch)
    card_resized = cv2.resize(card, (new_w, new_h), interpolation=cv2.INTER_AREA)

    # 2. Perspective-Verzerrung: jeden Eckpunkt um max ±max_perspective verschieben
    sh, sw = card_resized.shape[:2]
    src = np.float32([[0, 0], [sw, 0], [sw, sh], [0, sh]])
    dx_max = sw * max_perspective
    dy_max = sh * max_perspective
    dst = np.float32(
        [
            [rng.uniform(0, dx_max), rng.uniform(0, dy_max)],
            [sw - rng.uniform(0, dx_max), rng.uniform(0, dy_max)],
            [sw - rng.uniform(0, dx_max), sh - rng.uniform(0, dy_max)],
            [rng.uniform(0, dx_max), sh - rng.uniform(0, dy_max)],
        ]
    )
    M_persp = cv2.getPerspectiveTransform(src, dst)
    warped_persp = cv2.warpPerspective(
        card_resized,
        M_persp,
        (sw, sh),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0, 0),
    )

    # 3. Rotation um Zentrum
    angle = rng.uniform(-rotation_deg, rotation_deg)
    M_rot = cv2.getRotationMatrix2D((sw / 2, sh / 2), angle, 1.0)
    cos = abs(M_rot[0, 0])
    sin = abs(M_rot[0, 1])
    rot_w = int(sh * sin + sw * cos)
    rot_h = int(sh * cos + sw * sin)
    M_rot[0, 2] += (rot_w / 2) - sw / 2
    M_rot[1, 2] += (rot_h / 2) - sh / 2
    rotated = cv2.warpAffine(
        warped_persp,
        M_rot,
        (rot_w, rot_h),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0, 0),
    )

    # 4. Polygon der Eckpunkte transformieren (Perspective -> Rotation)
    pts_persp = cv2.perspectiveTransform(src.reshape(1, 4, 2), M_persp).reshape(4, 2)
    pts_homog = np.concatenate([pts_persp, np.ones((4, 1))], axis=1)
    pts_rotated = (M_rot @ pts_homog.T).T  # (4, 2)

    # 5. Auf target_size canvas platzieren (random Position so dass Polygon drin bleibt)
    rh, rw = rotated.shape[:2]
    if rw >= target_size or rh >= target_size:
        # Notfall: Karte zu gross, downscale
        scale_fit = min(target_size / rw, target_size / rh) * 0.95
        rotated = cv2.resize(
            rotated, (int(rw * scale_fit), int(rh * scale_fit)),
            interpolation=cv2.INTER_AREA,
        )
        pts_rotated = pts_rotated * scale_fit
        rh, rw = rotated.shape[:2]

    max_x = target_size - rw
    max_y = target_size - rh
    off_x = rng.randint(0, max(max_x, 0))
    off_y = rng.randint(0, max(max_y, 0))

    canvas = np.zeros((target_size, target_size, 4), dtype=np.uint8)
    canvas[off_y : off_y + rh, off_x : off_x + rw] = rotated
    poly = pts_rotated + np.array([off_x, off_y])

    return canvas, poly.astype(np.float32)


def _alpha_composite(bg: np.ndarray, fg_rgba: np.ndarray) -> np.ndarray:
    """Standard Alpha-Blend: bg HWC uint8 RGB, fg HWC4 uint8 RGBA."""
    alpha = fg_rgba[..., 3:4].astype(np.float32) / 255.0
    fg_rgb = fg_rgba[..., :3].astype(np.float32)
    bg_f = bg.astype(np.float32)
    out = fg_rgb * alpha + bg_f * (1 - alpha)
    return np.clip(out, 0, 255).astype(np.uint8)


def _augment_color(img: np.ndarray, rng: random.Random) -> np.ndarray:
    pil = Image.fromarray(img)
    # Brightness, Contrast, Color-Saturation, leichte Schaerfe
    pil = ImageEnhance.Brightness(pil).enhance(rng.uniform(0.7, 1.25))
    pil = ImageEnhance.Contrast(pil).enhance(rng.uniform(0.8, 1.2))
    pil = ImageEnhance.Color(pil).enhance(rng.uniform(0.75, 1.25))
    if rng.random() < 0.25:
        pil = pil.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.3, 1.2)))
    return np.array(pil)


def _add_noise(img: np.ndarray, rng: random.Random) -> np.ndarray:
    sigma = rng.uniform(0, 12)
    if sigma < 0.5:
        return img
    noise = np.random.normal(0, sigma, img.shape)
    return np.clip(img.astype(np.float32) + noise, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# 4. Sample-Generator + Label-Writer
# ---------------------------------------------------------------------------

def _polygons_overlap(p1: np.ndarray, p2: np.ndarray, iou_threshold: float = 0.45) -> bool:
    """Approximation: IoU der Axis-Aligned Bounding Boxes der Polygone."""
    x1a, y1a = p1[:, 0].min(), p1[:, 1].min()
    x2a, y2a = p1[:, 0].max(), p1[:, 1].max()
    x1b, y1b = p2[:, 0].min(), p2[:, 1].min()
    x2b, y2b = p2[:, 0].max(), p2[:, 1].max()
    inter_w = max(0, min(x2a, x2b) - max(x1a, x1b))
    inter_h = max(0, min(y2a, y2b) - max(y1a, y1b))
    inter = inter_w * inter_h
    area_a = (x2a - x1a) * (y2a - y1a)
    area_b = (x2b - x1b) * (y2b - y1b)
    union = area_a + area_b - inter
    if union <= 0:
        return False
    return (inter / union) > iou_threshold


def _generate_sample(
    card_pool: list[np.ndarray],
    external_bgs: list[Path],
    img_size: int,
    max_cards: int,
    rng: random.Random,
) -> tuple[np.ndarray, list[np.ndarray]]:
    bg = _pick_background(img_size, rng, external_bgs)
    n_cards = rng.randint(1, max_cards)
    composed = bg.copy()
    accepted_polys: list[np.ndarray] = []

    for _ in range(n_cards):
        for _retry in range(5):
            card = rng.choice(card_pool)
            warped, poly = _warp_card(card, img_size, rng)
            if any(_polygons_overlap(poly, p) for p in accepted_polys):
                continue
            composed = _alpha_composite(composed, warped)
            accepted_polys.append(poly)
            break

    composed = _augment_color(composed, rng)
    composed = _add_noise(composed, rng)
    return composed, accepted_polys


def _write_label(path: Path, polygons: list[np.ndarray], img_size: int) -> None:
    lines = []
    for poly in polygons:
        coords = poly.flatten() / img_size
        coords = np.clip(coords, 0, 1)
        lines.append("0 " + " ".join(f"{v:.6f}" for v in coords))
    path.write_text("\n".join(lines) + ("\n" if lines else ""))


def _write_data_yaml(output_dir: Path) -> None:
    yaml = (
        f"path: {output_dir.resolve().as_posix()}\n"
        "train: images/train\n"
        "val: images/val\n"
        "nc: 1\n"
        "names:\n"
        "  0: card\n"
    )
    (output_dir / "data.yaml").write_text(yaml)


# ---------------------------------------------------------------------------
# 5. CLI
# ---------------------------------------------------------------------------

@app.command()
def main(
    num_train: int = typer.Option(8000, help="Anzahl Trainings-Samples"),
    num_val: int = typer.Option(1000, help="Anzahl Validierungs-Samples"),
    output_dir: Path = typer.Option(
        Path("datasets/cards_obb"), help="Zielverzeichnis fuer Dataset"
    ),
    card_cache_dir: Path = typer.Option(
        Path("datasets/.card_cache"), help="Cache fuer Card-Bilder"
    ),
    backgrounds_dir: Path | None = typer.Option(
        None, help="Optionaler Ordner mit echten Background-Bildern"
    ),
    img_size: int = typer.Option(1280, help="Quadratische Output-Bild-Groesse"),
    max_cards: int = typer.Option(9, help="Max Karten pro Sample"),
    card_sample: int = typer.Option(
        5000, help="Wie viele unterschiedliche Karten aus DB cachen"
    ),
    concurrency: int = typer.Option(16, help="Parallele HTTP-Downloads"),
    seed: int = typer.Option(42, help="RNG-Seed (numpy + python)"),
) -> None:
    rng = random.Random(seed)
    np.random.seed(seed)

    settings = get_settings()
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True)

    console.print("[bold]1) DB-Sample[/bold]")
    with Session(engine) as session:
        rows = _sample_cards(session, card_sample)
    console.print(f"  {len(rows)} Karten aus DB gezogen")

    console.print("[bold]2) Card-Bilder cachen[/bold]")
    card_paths = asyncio.run(_cache_cards(rows, card_cache_dir, concurrency))
    console.print(f"  {len(card_paths)} Bilder im Cache")

    console.print("[bold]3) Card-Pool laden (RGBA)[/bold]")
    card_pool: list[np.ndarray] = []
    for p in card_paths:
        arr = _load_card_rgba(p)
        if arr is not None and arr.shape[0] > 50 and arr.shape[1] > 50:
            card_pool.append(arr)
    console.print(f"  {len(card_pool)} Karten geladen")
    if not card_pool:
        raise typer.Exit(code=1)

    external_bgs = _load_external_bgs(backgrounds_dir)
    if external_bgs:
        console.print(f"  {len(external_bgs)} externe Backgrounds verfuegbar")

    # Verzeichnisse anlegen
    for split in ("train", "val"):
        (output_dir / "images" / split).mkdir(parents=True, exist_ok=True)
        (output_dir / "labels" / split).mkdir(parents=True, exist_ok=True)

    _write_data_yaml(output_dir)

    console.print("[bold]4) Samples generieren[/bold]")
    for split, n in (("train", num_train), ("val", num_val)):
        with Progress(
            TextColumn(f"[progress.description]{{task.description}}"),
            BarColumn(),
            TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
            TimeElapsedColumn(),
            TimeRemainingColumn(),
            console=console,
        ) as prog:
            tid = prog.add_task(f"{split}", total=n)
            for i in range(n):
                img, polys = _generate_sample(
                    card_pool, external_bgs, img_size, max_cards, rng
                )
                img_path = output_dir / "images" / split / f"{i:06d}.jpg"
                lbl_path = output_dir / "labels" / split / f"{i:06d}.txt"
                cv2.imwrite(
                    str(img_path),
                    cv2.cvtColor(img, cv2.COLOR_RGB2BGR),
                    [cv2.IMWRITE_JPEG_QUALITY, 85],
                )
                _write_label(lbl_path, polys, img_size)
                prog.advance(tid)

    console.print(f"[green]Fertig: {output_dir.resolve()}[/green]")


if __name__ == "__main__":
    app()
