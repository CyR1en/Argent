"""The print stage's acceptance checks (docs/research/film-sim/print.md section 3): what they measure and on
what numbers, not which setup passes them."""

import numpy as np
import pytest

from argent_bake.print_checks import (BLACK_PATCH_LIMIT, CONTROL_LIMIT, DMAX_AIMS, REFERENCE, SLOPE_TOLERANCE, Setup,
                                      check_stock)
from argent_bake.printing import ToneStage
from tests.conftest import ENDURA, STOCK_NAMES

NAMES = ["tone", "mid-tone slope", "US7372597", "gray scale", "D-max", "neutral axis", "highlights",
         "gray card and white step"]


def test_the_limits_are_kodaks_published_numbers():
    assert CONTROL_LIMIT == 0.10 and BLACK_PATCH_LIMIT == 0.15  # Z-130 Table 7-1
    assert SLOPE_TOLERANCE == pytest.approx(0.10 / 0.85)
    assert DMAX_AIMS[ENDURA] == ((2.25, 2.20, 2.15), (2.45, 2.45, 2.40))  # CIS-289
    assert {figure for figure, _ in REFERENCE.values()} == {"FIG. 1", "FIG. 2"}


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_every_stock_is_checked_on_every_count(stocks, name):
    checks = check_stock(stocks[name], Setup(ENDURA))
    assert [c.name for c in checks] == NAMES
    # A paper is not held to US7372597's band (the patent places conventional prints outside it).
    assert checks[2].passed is None
    # The negative's gates do not depend on the print.
    assert checks[-1].passed


def test_an_identity_stage_changes_nothing(stocks):
    knots = np.repeat(np.array([[-6.0], [3.0]]), 3, axis=1)
    plain = check_stock(stocks["portra400"], Setup(ENDURA))
    staged = check_stock(stocks["portra400"], Setup(ENDURA, ToneStage(knots, knots, "identity")))
    assert [c.detail for c in plain if c.name != "US7372597"] == [c.detail for c in staged if c.name != "US7372597"]
    assert staged[2].passed is not None  # a stage is held to the band


# The decision of print.md section 4, by the rule of section 3: the three Portras print through a tone stage built
# from US5300381 FIG. 2 on ENDURA Premier; Ektar 100, Gold 200 and UltraMax 400 stay optical prints on ENDURA
# Premier, Ektar and Gold with the neutral-axis failure their sheets' curves bring, reported.
DECISION = {"portra400": "US5300381 FIG. 2", "portra160": "US5300381 FIG. 2", "portra800": "US5300381 FIG. 2",
            "ektar100": None, "gold200": None, "ultramax400": None}
REPORTED_FAILURES = {"ektar100": {"neutral axis"}, "gold200": {"neutral axis"}}


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_each_stock_prints_through_the_setup_the_rule_chose(stocks, name):
    from argent_bake.print_checks import setup_for
    profile = stocks[name]
    assert profile.paper == ENDURA and profile.print_stage == DECISION[name]
    failed = {c.name for c in check_stock(profile, setup_for(profile)) if c.passed is False}
    assert failed == REPORTED_FAILURES.get(name, set())


def test_kodaks_orders_hold_across_the_chosen_setups(stocks):
    from argent_bake.print_checks import check_orders, setup_for
    legacy = {name: stocks[name] for name in STOCK_NAMES}
    checks = check_orders(legacy, {name: setup_for(stock) for name, stock in legacy.items()})
    assert all(c.passed for c in checks), [c.detail for c in checks if not c.passed]
