import copy
import json

import numpy as np
import pytest

from argent_bake.densitometry import status_density, status_weights
from argent_bake.negative import MID_GRAY, dye_amounts
from argent_bake.paper import PaperError, fit_base, load_paper, paper_named, weight_centroids
from argent_bake.printing import Printer, calibrate
from argent_bake.spectral import WAVELENGTHS, blackbody, daylight
from tests.conftest import ENDURA, PAPERS


def test_the_endura_paper_loads_from_its_profile(endura):
    assert endura.name == ENDURA and endura.status == "datasheet" and endura.densitometry == "statusA"
    assert endura.sensitivity.shape == (81, 3) and endura.dyes.shape == (81, 3) and endura.base.shape == (81,)
    assert endura.curves.shape == endura.status_curves.shape == (58, 3)
    assert tuple(WAVELENGTHS[endura.sensitivity.argmax(axis=0)]) == (695, 550, 475)
    assert tuple(WAVELENGTHS[endura.dyes.argmax(axis=0)]) == (650, 550, 445)
    assert endura.dyes.max(axis=0) == pytest.approx(np.ones(3))
    assert np.array_equal(endura.enlarger, blackbody(3200.0)) and np.array_equal(endura.viewing, daylight(5003.0))


def test_2383_matches_kodaks_lab_aim_and_separates_projected_tones(stocks):
    film = paper_named("kodak-vision-2383")
    assert film.medium == "transmission" and film.densitometry == "statusA"
    assert film.inversion_residual < 0.001
    assert np.array_equal(film.viewing, blackbody(5400))
    assert tuple(WAVELENGTHS[film.sensitivity.argmax(axis=0)]) == (690, 550, 460)
    stock = stocks["vision3500t"]
    printer = Printer(film, stock.dyes, stock.base)
    gray = dye_amounts(stock, np.full(3, MID_GRAY))
    filtration = calibrate(printer, gray)
    expo = printer.log_exposure(gray) + filtration
    printed_dyes = np.array([np.interp(x, film.log_exposure, c) for x, c in zip(expo, film.curves.T)])
    measured = status_density(film.base + film.dyes @ printed_dyes, status_weights("A"))
    assert measured == pytest.approx([1.09, 1.06, 1.03], abs=1e-6)

    scale = np.repeat((MID_GRAY * 2.0 ** np.arange(-8, 9))[:, None], 3, axis=1)
    projected = printer(dye_amounts(stock, scale), filtration)
    assert np.all(np.diff(projected @ [0.2627, 0.678, 0.0593]) > 0)
    assert np.all((projected > 0) & (projected < 1))
    assert projected[0].max() < 0.001 and projected[-1].min() > 0.9


def test_transmission_requires_a_lab_aim_above_the_base():
    profile = json.loads((PAPERS / "kodak-vision-2383.json").read_text())
    profile["labAimDensity"][1] = 0
    with pytest.raises(PaperError, match="densities above the minimum"):
        load_paper(profile)


def test_dyes_and_sensitivities_follow_the_edge_rules(endura):
    # The sheet's cyan is still 0.42 at the 700 nm cut and is held there, not dropped to zero.
    assert endura.dyes[WAVELENGTHS == 780, 0][0] == pytest.approx(endura.dyes[WAVELENGTHS == 700, 0][0])
    assert endura.dyes[WAVELENGTHS == 700, 0][0] == pytest.approx(0.42, abs=0.01)
    # Sensitivity is zero outside each layer's plotted domain.
    assert endura.sensitivity[WAVELENGTHS == 380, 0][0] == 0.0 and endura.sensitivity[WAVELENGTHS == 780, 2][0] == 0.0


def test_the_base_reads_as_the_sheets_minimum_density():
    weights = status_weights("A")
    assert weight_centroids(weights) == pytest.approx([628.7, 535.6, 444.5], abs=0.1)
    minimum = np.array([0.105, 0.105, 0.080])
    base, knot_wl, knots = fit_base(minimum, weights)
    assert status_density(base, weights) == pytest.approx(minimum, abs=1e-9)
    assert knots == pytest.approx([0.1049, 0.1066, 0.0786], abs=0.001)
    assert base[0] == pytest.approx(knots[2]) and base[-1] == pytest.approx(knots[0])  # flat beyond the outer knots


def test_the_inversion_reproduces_the_status_a_curves(endura):
    weights = status_weights("A")
    reproduced = status_density(endura.base[None, :] + endura.curves @ endura.dyes.T, weights)
    residual = np.abs(reproduced - endura.status_curves).max(axis=1)
    pinned = (endura.curves <= 0).any(axis=1)
    # Toe rows where the sheet dips below its own minimum density pin an amount at zero; the rest solve exactly.
    assert np.all(residual[~pinned] < 1e-6)
    assert residual[pinned].max() < 0.003 and np.all(endura.log_exposure[pinned] <= -2.2)
    assert endura.inversion_residual == pytest.approx(residual.max())
    assert endura.curves.min() >= 0.0


def test_the_d_max_amounts_are_on_record(endura):
    # Phase 1 measured 2.93 / 2.17 / 2.16 with the dyes cut to zero beyond 700 nm; with the cyan held at
    # 0.42 there, the red layer needs less cyan to reach the same Status A red.
    row = endura.status_curves[:, 0].argmax()
    assert endura.log_exposure[row] == pytest.approx(-0.40)
    assert endura.curves[row] == pytest.approx([2.749, 2.188, 2.167], abs=0.01)
    assert endura.curves.max(axis=0) == pytest.approx([2.749, 2.190, 2.168], abs=0.01)


def test_amounts_rise_with_exposure_up_to_d_max(endura):
    rising = (endura.log_exposure >= -2.2) & (endura.log_exposure <= -0.4)
    assert np.all(np.diff(endura.curves[rising], axis=0) >= -1e-6)


def test_paper_lookup_resolves_the_synthetic_and_the_profiles():
    assert paper_named("synthetic-print-v0").name == "synthetic-print-v0"
    assert paper_named(ENDURA).name == ENDURA
    with pytest.raises(ValueError, match="no print paper named"):
        paper_named("shared-print-model-v1")


@pytest.mark.parametrize("mutate, message", [
    (lambda d: d.update(status="placeholder"), "placeholder"),
    (lambda d: d.update(schema=5), "schema 5"),
    (lambda d: d["dyeDensity"].pop("magenta"), "dyeDensity.magenta"),
    (lambda d: d["characteristicCurves"]["red"].__setitem__(5, 9.0), "must not fall"),
    (lambda d: d["minimumDensity"].update(statusA=[0.1, 0.1]), "three non-negative"),
    (lambda d: d.update(enlarger={"kind": "led", "kelvin": 3200}), "blackbody or daylight"),
    (lambda d: d.update(viewing={"kind": "daylight", "kelvin": 3200}), "4000 to 25000"),
    (lambda d: d["spectralSensitivity"]["red"].__setitem__(10, 1000), "finite, positive spectral sensitivity"),
    (lambda d: d.pop("viewing"), "viewing needs a kind"),
])
def test_malformed_papers_say_what_is_wrong(mutate, message):
    data = copy.deepcopy(json.loads((PAPERS / f"{ENDURA}.json").read_text()))
    mutate(data)
    with pytest.raises(PaperError, match=message):
        load_paper(data)


@pytest.mark.parametrize("value", [None, [], "paper", 1])
def test_a_paper_profile_must_be_a_json_object(value, tmp_path):
    path = tmp_path / "paper.json"
    path.write_text(json.dumps(value))
    with pytest.raises(PaperError, match="JSON object"):
        load_paper(path)


@pytest.mark.parametrize("value", [float("nan"), float("inf"), float("-inf"), None])
def test_minimum_density_must_be_finite(value):
    data = json.loads((PAPERS / f"{ENDURA}.json").read_text())
    data["minimumDensity"]["statusA"][0] = value
    with pytest.raises(PaperError, match="minimumDensity.statusA.*finite"):
        load_paper(data)


@pytest.mark.parametrize("section, key", [("spectralSensitivity", "wavelengths"),
                                         ("characteristicCurves", "logExposure"),
                                         ("dyeDensity", "wavelengths")])
@pytest.mark.parametrize("value", [float("nan"), float("inf"), float("-inf")])
def test_paper_axes_must_be_finite(section, key, value):
    data = json.loads((PAPERS / f"{ENDURA}.json").read_text())
    data[section][key][-1] = value
    with pytest.raises(PaperError, match="finite and strictly increasing"):
        load_paper(data)


@pytest.mark.parametrize("kelvin", [0, -3200, float("nan"), float("inf"), 1])
def test_blackbody_illuminants_must_produce_finite_light(kelvin):
    data = json.loads((PAPERS / f"{ENDURA}.json").read_text())
    data["enlarger"]["kelvin"] = kelvin
    with pytest.raises(PaperError, match="enlarger.*finite"):
        load_paper(data)


@pytest.mark.parametrize("absolute", [False, True])
def test_paper_names_cannot_read_profiles_outside_the_resource_directory(tmp_path, monkeypatch, absolute):
    resources = tmp_path / "papers"
    resources.mkdir()
    outside = tmp_path / "outside.json"
    name = str(outside.with_suffix("")) if absolute else "../outside"
    data = json.loads((PAPERS / f"{ENDURA}.json").read_text())
    data["id"] = name
    outside.write_text(json.dumps(data))
    monkeypatch.setattr("argent_bake.paper.PAPERS_DIR", resources)
    with pytest.raises(ValueError, match="no print paper named"):
        paper_named(name)


# The papers digitized for work package E (docs/research/film-sim/print.md section 2) by tools/paper_from_sheet.py.
DIGITIZED_2026_10_08 = {
    # id: (publication, D-max R G B as the sheet's curves reach it, sensitivity peaks, dye peaks)
    "kodak-portra-endura": ("E-4021", (2.657, 2.655, 2.429), (700, 550, 475), (630, 550, 445)),
    "kodak-supra-endura": ("E-4021", (2.654, 2.590, 2.518), (700, 550, 475), (630, 550, 445)),
    "kodak-supra-endura-vc-digital": ("E-4042", (2.740, 2.607, 2.550), (695, 550, 475), (630, 565, 465)),
}


@pytest.mark.parametrize("name", sorted(DIGITIZED_2026_10_08))
def test_the_papers_of_package_e_load_and_invert(name):
    publication, dmax, sensitivity_peaks, dye_peaks = DIGITIZED_2026_10_08[name]
    paper = paper_named(name)
    data = json.loads((PAPERS / f"{name}.json").read_text())
    assert data["source"]["publication"] == publication and paper.status == "datasheet"
    assert paper.densitometry == "statusA"
    assert paper.status_curves.max(axis=0) == pytest.approx(dmax, abs=0.002)
    assert tuple(WAVELENGTHS[paper.sensitivity.argmax(axis=0)]) == pytest.approx(sensitivity_peaks, abs=5)
    assert tuple(WAVELENGTHS[paper.dyes.argmax(axis=0)]) == pytest.approx(dye_peaks, abs=5)
    assert paper.inversion_residual < 0.003 and paper.curves.min() >= 0.0
    # Kodak's order of the papers' contrast: PORTRA ENDURA "a low contrast paper", SUPRA ENDURA "slightly higher
    # contrast" (E-4021); the steepest part of each curve, red, green and blue.
    peak = np.gradient(paper.status_curves, paper.log_exposure, axis=0).max(axis=0)
    assert np.all(peak > 2.5) and np.all(peak < 5.0)


def test_portra_endura_is_the_softest_paper_as_its_sheet_says():
    peaks = {name: np.gradient(paper_named(name).status_curves, paper_named(name).log_exposure, axis=0).max(axis=0).mean()
             for name in ("kodak-portra-endura", "kodak-supra-endura", ENDURA)}
    assert peaks["kodak-portra-endura"] < peaks["kodak-supra-endura"] < peaks[ENDURA]


def test_e4021s_two_papers_share_the_sheets_one_sensitivity_and_dye_plot():
    portra, supra = (json.loads((PAPERS / f"{n}.json").read_text()) for n in ("kodak-portra-endura", "kodak-supra-endura"))
    assert portra["spectralSensitivity"] == supra["spectralSensitivity"]
    assert portra["dyeDensity"] == supra["dyeDensity"]
