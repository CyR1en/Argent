import copy
import json

import numpy as np
import pytest

from argent_bake import synthetic
from argent_bake.profile import ProfileError, load_profile
from tests.conftest import STOCKS, STOCK_NAMES


def test_the_synthetic_profile_loads_through_the_same_path_as_a_file(tmp_path):
    path = tmp_path / "synthetic.json"
    path.write_text(json.dumps(synthetic.profile_dict()))
    from_file = load_profile(path)
    from_dict = synthetic.profile()
    assert from_file.id == from_dict.id == "synthetic-v0"
    assert np.array_equal(from_file.curves, from_dict.curves)
    assert np.array_equal(from_file.amount_curves, from_dict.amount_curves)
    assert from_file.sensitivity.shape == (81, 3) and from_file.dyes.shape == (81, 3) and from_file.base.shape == (81,)


def test_explicit_dyes_are_normalized_to_a_unit_peak_and_the_base_is_clear():
    profile = synthetic.profile()
    assert profile.dyes.max(axis=0) == pytest.approx(np.ones(3))
    assert np.all(profile.base == 0)
    assert profile.negative_model["rms"] is None and profile.negative_model["method"].startswith("explicit")
    assert profile.gray_card is not None and profile.log_exposure_reference is not None


def test_sensitivity_is_zero_outside_the_measured_range_and_linear_inside():
    data = synthetic.profile_dict()
    data["spectralSensitivity"]["wavelengths"] = [450.0 + 10 * i for i in range(len(data["spectralSensitivity"]["red"]))]
    sensitivity = load_profile(data).sensitivity
    assert sensitivity[0, 0] == 0.0  # 380 nm is below the first measured wavelength
    assert sensitivity.max() <= 1.0 + 1e-9


def test_a_null_in_a_sensitivity_array_means_no_response_there():
    data = synthetic.profile_dict()
    data["spectralSensitivity"]["red"][:5] = [None] * 5
    sensitivity = load_profile(data).sensitivity
    assert np.all(sensitivity[:9, 0] == 0.0) and sensitivity[10, 0] > 0  # 380 to 420 nm null, 430 nm responds


def test_the_placeholder_status_is_refused_with_a_clear_message():
    data = synthetic.profile_dict()
    data["status"] = "placeholder"
    with pytest.raises(ProfileError, match="placeholder"):
        load_profile(data)


def test_a_missing_file_is_a_profile_error(tmp_path):
    with pytest.raises(ProfileError, match="cannot read"):
        load_profile(tmp_path / "nope.json")


@pytest.mark.parametrize("value", [float("nan"), float("inf"), float("-inf"), True, False])
@pytest.mark.parametrize("field", [
    "boxSpeed", "logExposureReference", "strength", "greenShare", "radiusMicrometres",
    "redDensity", "whiteStepRedDensity", "lightComplexion", "darkComplexion",
])
def test_numeric_scalars_must_be_finite_and_not_boolean(field, value):
    data = synthetic.profile_dict()
    if field == "boxSpeed":
        data[field] = value
    elif field == "logExposureReference":
        data["characteristicCurves"][field] = value
    elif field in ("strength", "greenShare", "radiusMicrometres"):
        data["halation"] = {"strength": 0.1, "greenShare": 0.2, "radiusMicrometres": 10}
        data["halation"][field] = value
    elif field in ("redDensity", "whiteStepRedDensity"):
        data["grayCard"][field] = [0, value]
    else:
        data["grayCard"]["foreheadRedDensity"] = {"lightComplexion": [0, 1], "darkComplexion": [0, 1]}
        data["grayCard"]["foreheadRedDensity"][field] = [0, value]
    with pytest.raises(ProfileError, match=field):
        load_profile(data)


@pytest.mark.parametrize("mutate, message", [
    (lambda d: d["characteristicCurves"].update(red=d["characteristicCurves"]["red"][:-1]), "values, expected"),
    (lambda d: d["characteristicCurves"].update(logExposure=list(reversed(d["characteristicCurves"]["logExposure"]))),
     "strictly increasing"),
    (lambda d: d["characteristicCurves"]["green"].__setitem__(10, 99.0), "must not fall"),
    (lambda d: d["characteristicCurves"]["blue"].__setitem__(0, -1.0), "negative density"),
    (lambda d: d["dyeDensity"]["cyan"].__setitem__(3, -0.2), "negative"),
    (lambda d: d["dyeDensity"].update(magenta=[0.0] * len(d["dyeDensity"]["magenta"])), "no density"),
    (lambda d: d["dyeDensity"].pop("cyan"), "dyeDensity needs either"),
    (lambda d: d["couplers"].update(interLayer=[[0, 0], [0, 0]]), "3 by 3"),
    (lambda d: d["couplers"]["interLayer"][0].__setitem__(1, -0.1), "must not be negative"),
    (lambda d: d.update(boxSpeed=0), "boxSpeed"),
    (lambda d: d["spectralSensitivity"].pop("blue"), "spectralSensitivity.blue"),
    (lambda d: d["spectralSensitivity"]["green"].__setitem__(2, float("nan")), "not finite"),
    (lambda d: d["characteristicCurves"]["red"].__setitem__(2, None), "must not contain null"),
    (lambda d: d.update(schema=3), "schema 3"),
    (lambda d: d.update(grayCard={"redDensity": [0.9, 0.8]}), "low below high"),
    (lambda d: d.update(grayCard={"redDensity": [0.8, 0.9], "whiteStepRedDensity": [1.3, 1.2]}), "low below high"),
    (lambda d: d.update(grayCard={"redDensity": [0.8, 0.9], "foreheadRedDensity": {"lightComplexion": [1.0, 1.1]}}),
     "lightComplexion and darkComplexion"),
    (lambda d: d.update(modelledFilm=" "), "modelledFilm must name"),
    (lambda d: d.update(modelledFilm=400), "modelledFilm must name"),
    (lambda d: d.update(exposureMatrix={"matrix": [[1, 0], [0, 1]]}), "exposureMatrix.matrix must be a 3 by 3"),
    (lambda d: d.update(exposureMatrix={"matrix": [[1.1, 0, 0], [0, 1, 0], [0, 0, 1]]}), "rows must sum to one"),
    (lambda d: d.update(exposureMatrix={"matrix": [[0, 1, 0], [0, 1, 0], [0, 0, 1]]}), "by its own primary"),
])
def test_malformed_profiles_say_what_is_wrong(mutate, message):
    data = copy.deepcopy(synthetic.profile_dict())
    mutate(data)
    with pytest.raises(ProfileError, match=message):
        load_profile(data)


@pytest.mark.parametrize("remove, message", [
    ("source", "requires a source"),
    ("grayCard", "requires grayCard"),
    ("logExposureReference", "requires characteristicCurves.logExposureReference"),
    ("modelledFilm", "requires modelledFilm"),
])
def test_a_datasheet_profile_must_carry_its_provenance_and_checks(remove, message):
    data = json.loads((STOCKS / "portra400.json").read_text())
    if remove == "logExposureReference":
        data["characteristicCurves"].pop(remove)
    else:
        data.pop(remove)
    with pytest.raises(ProfileError, match=message):
        load_profile(data)


def test_a_sheet_form_profile_needs_the_midscale_above_the_minimum():
    data = json.loads((STOCKS / "portra400.json").read_text())
    data["dyeDensity"]["midscaleNeutral"][10] = data["dyeDensity"]["minimumDensity"][10] - 0.01
    with pytest.raises(ProfileError, match="must lie above minimumDensity"):
        load_profile(data)


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_every_datasheet_stock_loads_with_unmixed_dyes_and_a_base(stocks, name):
    profile = stocks[name]
    assert profile.status == "datasheet" and profile.paper == "kodak-endura-premier"
    assert profile.dyes.shape == (81, 3) and profile.dyes.max(axis=0) == pytest.approx(np.ones(3))
    assert profile.base.shape == (81,) and profile.base.min() > 0.1
    assert profile.amount_curves.shape == profile.curves.shape and np.all(np.isfinite(profile.amount_curves))
    assert profile.gray_card[0] < profile.gray_card[1]
    assert profile.log_exposure_reference is not None
    model = profile.negative_model
    assert set(model) >= {"method", "rms", "maxError", "crossTalk", "parameters", "midscaleAmounts"}
    assert np.asarray(model["crossTalk"]).shape == (3, 3)
    # The sensitivities keep every null as no response and every plotted sample as a response.
    assert np.all(profile.sensitivity.max(axis=0) > 0)


def test_sensitivity_nulls_are_kept_as_no_response_in_a_real_profile(stocks):
    # Gold 200's red layer runs along the plot floor from 455 to 485 nm, which the profile stores as null.
    from argent_bake.spectral import WAVELENGTHS
    gold = stocks["gold200"]
    inside = (WAVELENGTHS >= 455) & (WAVELENGTHS <= 485)
    assert np.all(gold.sensitivity[inside, 0] == 0.0)
    assert gold.sensitivity[WAVELENGTHS == 450, 0][0] > 0 and gold.sensitivity[WAVELENGTHS == 490, 0][0] > 0


def test_loading_is_deterministic(stocks):
    again = load_profile(STOCKS / "portra400.json")
    assert np.array_equal(again.dyes, stocks["portra400"].dyes)
    assert np.array_equal(again.amount_curves, stocks["portra400"].amount_curves)
    assert again.negative_model == stocks["portra400"].negative_model
