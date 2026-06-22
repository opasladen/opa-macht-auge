"""Domain enums and value objects for cards."""
from __future__ import annotations

from enum import StrEnum


class Language(StrEnum):
    DE = "de"
    EN = "en"
    FR = "fr"
    IT = "it"
    ES = "es"
    PT = "pt"
    JP = "jp"
    KO = "ko"
    ZH = "zh"


class Edition(StrEnum):
    UNLIMITED = "unlimited"
    FIRST_EDITION = "1st_edition"
    SHADOWLESS = "shadowless"
    PROMO = "promo"


class Finish(StrEnum):
    REGULAR = "regular"
    HOLO = "holo"
    REVERSE_HOLO = "reverse_holo"
    FULL_ART = "full_art"
    RAINBOW = "rainbow"
    GOLD = "gold"
    TEXTURED = "textured"


class Condition(StrEnum):
    """Cardmarket-konforme Zustandsklassen."""

    MINT = "M"
    NEAR_MINT = "NM"
    EXCELLENT = "EX"
    GOOD = "GD"
    LIGHT_PLAYED = "LP"
    PLAYED = "PL"
    POOR = "PO"
