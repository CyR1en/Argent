from pathlib import Path

import pytest

from argent_bake.paper import paper_named
from argent_bake.profile import load_profile

BAKE = Path(__file__).resolve().parents[1]
STOCKS = BAKE / "stocks"
PAPERS = BAKE / "papers"
STOCK_NAMES = ("portra400", "portra160", "portra800", "ektar100", "gold200", "ultramax400")
NEW_STOCK_NAMES = ("superia400", "pro400h", "c200", "colorplus200", "vision3500t", "cinestill800t", "portra160natural")
ENDURA = "kodak-endura-premier"


@pytest.fixture(scope="session")
def stocks() -> dict:
    """Stock profiles, loaded once: the unmixing runs 24 fits per profile."""
    return {name: load_profile(STOCKS / f"{name}.json") for name in (*STOCK_NAMES, *NEW_STOCK_NAMES)}


@pytest.fixture(scope="session")
def endura():
    return paper_named(ENDURA)
