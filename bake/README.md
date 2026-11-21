# argent-bake

The offline half of Argent. It turns a stock profile in `stocks/` and a paper profile in
`papers/` into the folder the app loads: a Negative LUT, a Print LUT and a manifest. The tool
does not ship in the app; the baked folders do.

Ten stocks are based on Kodak or Fujifilm datasheets; ColorPlus 200 and CineStill 800T use
labeled proxy data. Portra Natural uses Portra 160 with 60% interlayer coupling,
a chosen rendering rather than a measured film.
The base stocks print on ENDURA Premier; the Portras add a lab tone stage from
US5300381 FIG. 2. Cinema 500 is the bundled print variant of Tungsten 500 that models
projection through Kodak VISION Color Print Film 2383. That makes 14 looks in the app.
None is fitted to scans.

## Usage

From `bake/`:

```
python3 -m venv ../.venv
../.venv/bin/python -m pip install -e '.[test]'
../.venv/bin/python -m argent_bake bake --profile stocks/portra400.json --out /tmp/portra-400
../.venv/bin/python -m argent_bake bake --all --out /tmp/stocks          # base stocks and print variants
../.venv/bin/python -m argent_bake bake --profile stocks/vision3500t.json --print-variant kodak-vision3-500t-cinema --out /tmp/cinema-500
../.venv/bin/python -m argent_bake check --profile stocks/portra400.json  # the gates; exit 1 on a failure
../.venv/bin/python -m argent_bake bake --synthetic --out /tmp/synthetic-stock
../.venv/bin/python -m pytest
```

`--size` sets the LUT size per axis (default 65). `bake` runs the gates first and refuses a
failing profile with exit code 2, writing nothing.

`scripts/build-app.sh` bakes all stocks at size 65 into `build/stocks` whenever a file under
`argent_bake/`, `stocks/` or `papers/` changes, and bundles them into the app. To check that the
Swift side reads a bake: `ARGENT_BAKED_STOCK=<folder> swift test --filter BakedStockContractTests`.

Loading a datasheet profile runs its deterministic unmixing fit, and the Portras' tone stage adds
work before LUT evaluation, so bake time depends on the stock, LUT size and machine.

## Layout

| Path | Contents |
| --- | --- |
| `argent_bake/__main__.py`, `bake.py` | the CLI and the bake |
| `profile.py`, `negative.py`, `unmixing.py`, `densitometry.py` | the negative |
| `printing.py`, `paper.py`, `print_tone.py`, `print_stage.py` | the print and the Portras' tone stage |
| `checker.py`, `print_checks.py` | the gates and the print-stage acceptance checks |
| `spectral.py`, `encoding.py`, `cube.py`, `grain.py`, `halation.py` | CIE colour, log encoding, LUT files, grain table, halation inputs |
| `synthetic.py` | the synthetic stock |
| `argent_bake/data/` | CIE and ISO 5-3 tables ([data/README.md](argent_bake/data/README.md)) |
| `stocks/`, `papers/` | twelve negative stock profiles, six paper profiles and one projection print film |
| `tools/` | one-off fits and digitizations whose outputs are in the profiles (couplers, exposure matrices, papers, halation geometry, toe, skin locus, scan grain) |
| `tests/` | pytest by area (negative, printing, paper, print tone and checks, grain, halation, spectral, cube, profile, bake), plus stock provenance and a Portra 400 regression pin |

## What it writes

```
stock.json       manifest, schema 2: identity, box speed, density range, LUT files, log
                 encoding, exposure per unit dye, grain table, halation, status, provenance
negative.cube    log-encoded scene-linear Rec. 2020 RGB -> dye amounts / density range
negative.lut3d   the same table, binary
print.cube       dye amounts / density range -> display-linear Rec. 2020 RGB
print.lut3d      the same table, binary
```

`Stock.load` in `ArgentCore` reads the folder and accepts manifest schema 1 and 2. The binary
file is 8 ASCII bytes `ARGLUT3D`, uint32 version 1, uint32 size, then size³ × 3 little-endian
float32 in `.cube` order. The loader prefers it when the manifest names it and it exists, and
falls back to the `.cube`; the bake writes both from one table.

## Conventions the Swift side relies on

- Working space: scene-linear, Rec. 2020 primaries. The Negative LUT's input is that space
  log-encoded per channel: 0 is eight stops below mid-gray (0.18), 1 is eight stops above
  for the film stocks, or five above for the synthetic stock. Swift reads the domain
  from the manifest, including the original five-stop bakes.
- `.cube` order: red fastest, then green, then blue. The binary file matches.
- The Negative LUT outputs the amounts of the negative's cyan, magenta and yellow dyes (each a
  unit-peak spectral density) divided by `densityRange`. The Print LUT reads the same units and
  applies the base and mask. Schema 1 stored Status M densities instead.
- `densityRange` is the larger of the plotted dye-amount peak and the Negative LUT grid's peak,
  rounded up to 0.5.
  The headroom lets lab balance move the Print LUT's input past ordinary amounts.
- `print.exposurePerUnit[c]` is log10 paper exposure of layer c per unit of negative dye c at the
  daylight reference (0 red/cyan, 1 green/magenta, 2 blue/yellow). Stops of lab balance or print
  exposure become a Print LUT input offset of `stops * log10(2) / (exposurePerUnit[c] *
  densityRange)`. Schema 1 has no such field; Swift uses 1.0.
- The Print LUT outputs display-linear Rec. 2020; paper white is (1, 1, 1).
- Daylight reference: scene mid-gray at box speed, Rated at at box speed, no lab balance, prints
  as neutral 0.18. The bake solves for that filtration and folds it into the Print LUT.
- A positive Print LUT input offset lightens the print (a denser negative passes less light).

## The model

The negative (`negative.py`, `profile.py`, `unmixing.py`, `densitometry.py`):

1. Working-space RGB becomes relative layer exposure through a 3 by 3 matrix whose rows sum to
   one, exact on neutrals. The original six Kodak stocks use matrices fitted to measured natural
   reflectances and regularized against input error (`docs/research/film-sim/matrix.md`).
   Fujifilm and the synthetic stock use a smooth reflectance basis under CIE D55. The two
   tungsten stocks set `captureIlluminantKelvin` to use a 3200 K blackbody for this basis.
2. Layer exposure is normalized by mid-gray's response, leaving only the colour response.
3. Mid-gray sits at 11.49 / box speed lux-seconds: an ISO 2720 meter reading (K 12.5, q 0.65)
   plus Kodak R-27's half stop. The original six gray-card windows intersect at H × S between
   11.0 and 11.6. For the two tungsten stocks the digitized camera-stop axis is anchored at
   that metered mid-gray; the published reference value is kept separately.
4. If a sheet publishes only Midscale Neutral and Minimum Density spectra, the dyes are unmixed:
   their difference is fitted by three unimodal asymmetric power-exponential lobes (exponents
   1.5 to 2.5, no secondary lobes; cyan symmetric because the sheets stop at 700 nm), by
   Levenberg-Marquardt from 24 seeded starts, so the fit is deterministic.
5. Each characteristic curve is inverted to non-negative dye amounts over the Minimum Density
   spectrum. The reference curves remain unchanged, with straight extensions past the plots.
   Fujifilm inversions use the change above each layer's plotted toe over the spectral minimum,
   because the plotted toes and the spectral minimum disagree in absolute density.
6. Inter-layer couplers lower a layer's effective exposure by how far its neighbours developed
   past a neutral exposure. The legacy Kodak couplers fit published gamma ratios for an
   inferred film class. Fujifilm uses no additional coupling; the ColorPlus proxy uses 80%
   of Gold's coupling as a qualitative, unmeasured saturation adjustment.
7. Except where a profile sets `highlightShoulder: "published"`, the negative bake reads each
   film curve unchanged up to +3 stops from mid-gray. Above the
   knee, each layer reads the curve at `3 + 2.5 × (1 − exp(−(stops − 3) / 2.5))`. The
   slope joins continuously at the knee and approaches zero toward +5.5 effective stops.
   This is a shared rendering model, not a measured shoulder. It does not change the source
   plots, mid-gray calibration, or the Paper LUT model. The tungsten stocks use their plotted
   highlight roll-off directly instead of applying a second shoulder.

The print (`printing.py`, `paper.py`):

1. A 3200 K blackbody enlarger shines through the negative: base and mask plus dye amounts times
   dye spectra.
2. Each paper layer integrates that light against its sensitivity, with a per-layer log-exposure
   offset for filtration and time. A stock with `printStage` adds a monotone per-layer exposure
   map that follows the published film-and-paper tone curve: the Portras name `US5300381 FIG.
   2`; Ektar, Gold and UltraMax print optically (`docs/research/film-sim/print.md`).
3. The paper's Status A curves are inverted to paper dye amounts over a three-knot base spectrum
   fitted to the sheet's minimum density. Net amounts keep paper white at (1, 1, 1), within
   dE2000 0.01 of Bradford adaptation to paper white on neutrals.
4. Paper dyes give a reflectance spectrum; CIE D50 gives XYZ; Bradford takes D50 to D65; the
   result is linear Rec. 2020.

Colour science (`spectral.py`): CIE's own 1931 2 degree observer, and daylight from CIE's S0, S1,
S2 through the CIE 15:2004 formula (D50 at 5003 K, D55 at 5503 K). No analytic stand-ins.

## Profiles

A stock profile is JSON in the datasheet's units. Schema 2 holds the sensitivities (null outside
a layer's plotted domain), Status M curves with Log H Ref, the Midscale Neutral and Minimum
Density spectra, the gray-card window, couplers, halation, grain, the paper, and for datasheet
profiles the fitted `exposureMatrix` and optional `printStage`. A synthetic or fitted profile may
give explicit dye spectra instead. `tools/profile_from_extraction.py` writes the six stock
profiles from the reviewed digitizations under `references/` (git-ignored; the Kodak PDFs live
there too).

| Profile | Status | Source | Box | ISO 5800 from the curves | Gray card red at mid-gray (window) |
| --- | --- | --- | --- | --- | --- |
| `kodak-portra-400` | datasheet | E-4050, 2025-01 | 400 | 398 | 0.835 (0.77 to 0.87) |
| `kodak-portra-160` | datasheet | E-4051, 2025-01 | 160 | 145 | 0.800 (0.79 to 0.89) |
| `kodak-portra-800` | datasheet | E-4040, 2025-01, EI 800 curves | 800 | 714 | 0.855 (0.75 to 0.95) |
| `kodak-ektar-100` | datasheet | E-4046, 2025-01 | 100 | 99 | 0.868 (0.77 to 0.87) |
| `kodak-gold-200` | datasheet | E-7022, 2023-06 | 200 | 207 | 0.865 (0.85 to 1.05) |
| `kodak-ultramax-400` | datasheet | E-7023, 2016-02 | 400 | 495 | 0.903 (0.80 to 1.00) |
| `fujifilm-superia-400` | datasheet | AF3-0217E | 400 | not a speed reference | 0.928 (0.75 to 0.95) |
| `fujifilm-pro-400h` | datasheet | AF3-176E | 400 | not a speed reference | not published |
| `fujifilm-c200` | datasheet | AF3-0249E | 200 | not a speed reference | not published |
| `kodak-colorplus-200` | approximation | Gold 200 proxy | 200 | not measured | not measured |
| `kodak-vision3-500t` | datasheet | H-1-5219, 2026-03, AHU version | 500 | not a speed reference | no window |
| `cinestill-800t` | approximation | CineStill Cs41 curves; VISION3 500T spectral proxy | 800 | not a speed reference | no window |
| `kodak-portra-160-natural` | approximation | E-4051, Portra 160 with 60% couplers | 160 | 145 | 0.800 (0.79 to 0.89) |
| `synthetic-v0` | synthetic | `synthetic.py` | 400 | not gated | its own window |

The Fujifilm profiles include PDF URLs, page numbers and file hashes. Pro 400H models
three dye records; its fourth color-sensitive layer is not independently characterized.
No unpublished Fuji coupler or halation estimates are included.

Tungsten 500 uses Kodak's published 3200 K ECN-2 curves, spectra and RMS granularity;
Tungsten 800 uses CineStill's published 3200 K Cs41 curves but no grain estimate or measured
spectra. Its VISION3 500T spectral proxy does not imply a shared emulsion. The bake uses Status M
as an approximation for the tungsten negative charts' densitometry. The halo inputs are estimates,
not point-source measurements: 500T with
anti-halation undercoat uses 1% strength, 180 µm radius and 15% green share; 800T without remjet
uses 14%, 270 µm and 6%, respectively, for a broader, redder halo.

Papers: `kodak-endura-premier` (E-4070, 2017-12, the base stocks' paper),
`kodak-portra-endura` and `kodak-supra-endura` (E-4021, 2008-09), `kodak-supra-endura-vc-digital`
(E-4042, 2008-07), `kodak-edge` (E-7020, 2017-12), `kodak-royal-digital` (E-7021, 2019-04).
The `kodak-vision-2383` projection profile is used only by Cinema 500; see
`docs/provenance.md` for the LAD, spectral sources, and approximations.

| `status` | Meaning |
| --- | --- |
| `placeholder` | Fields empty; the bake refuses it. |
| `synthetic` | Invented numbers that exercise the pipeline; not a look. |
| `datasheet` | Digitized curves, not fitted to scans. Carries its source and `modelledFilm`; a missing Log H Ref or gray-card window is recorded as null. |
| `fitted` | Fitted to ground-truth scans. None exists. |
| `approximation` | At least one material input is an explicitly identified proxy, not a measurement of the named film. |

The bake copies `status` into the manifest; `argent-spike` prints a note for anything but
`fitted`. `displayName` is the name the app shows (Portra 400 for `kodak-portra-400`);
`modelledFilm` ("Kodak Portra 400") appears in the app's descriptive line. Recipes refer to
stocks by id.

## The gates

`check --profile X` prints them and exits 1 on a failure; the tests run them on every stock.

| Gate | Rule | Legacy Kodak measurements |
| --- | --- | --- |
| Gray card | red density at mid-gray inside the sheet's window widened by 0.02 D | all inside, Ektar by 0.002 D before the margin |
| White step | red density of the lightest Paper Gray Scale step (0.1) inside the window widened by 0.04 D | all pass |
| ISO 5800 speed | from the curves (green and slowest layer at D-min + 0.15, S = √2 / √(H_G H_S)), within half a stop of box for speed-reference plots only | -0.16 to +0.31 stops |
| Unmixing | RMS under 0.012 D over the sheet's dye plot | 0.0041 to 0.0061 D |
| Cross-talk | Status M blue per unit magenta under 0.15, green per unit cyan under 0.22 | 0.037 to 0.056, 0.124 to 0.193 |
| Inversion | residual under 1e-6 D where every amount is positive; under 0.01 D in toe rows where one pins at zero | under 1e-10 D; Portra 160 and Ektar pin two and five toe rows at 3e-4 and 6.5e-3 D |
| Monotonic amounts | never fall by more than 0.002 plus what the printed curves fall | at most 0.0015; Gold 0.0105 against its printed 0.031 D blue toe dip |
| Density range | reported at size 65, holds the plotted and grid peaks | 2.5 to 3.5 |

The pinned toe rows come from the sheets: the Minimum Density spectrum reads a few thousandths
above the curve's toe in one channel, which no non-negative dye can lower. `check` also reports
print tone and the print-stage acceptance checks (`docs/research/film-sim/print.md`);
their tests cover each stock and the six stocks' saturation and contrast orders, but the exit
code follows the negative gates only.

The synthetic stock (`synthetic.py`) builds a stock and paper from logistic and Gaussian shapes,
in schema 2's explicit-dye form, through the same inversion, so the pipeline has a non-film to
test on. Its ISO 5800 and cross-talk gates are informational.

## What the model still simplifies

- RGB-to-layer exposure is a linear fit: three channels cannot recover a spectrum, and colours
  near the Rec. 2020 primaries can floor rather than gamut map.
- Couplers fit published gamma ratios for an inferred film class, not each stock's measured
  interimage; no datasheet publishes it.
- Dye cross-talk is a modelling prior. Several dye sets fit the sheet within a few thousandths of a
  density; this fit gives green per unit cyan 0.12 to 0.19 and blue per unit magenta 0.04 to 0.06
  (a cyan exponent pinned at 2 gives 0.09 to 0.14 at 0.0003 to 0.0014 D worse rms). The manifest
  records the matrix.
- No scan correction LUT: scan-fitted stocks need the real-scan protocol in
  `docs/research/film.md`.
- No push or pull. Portra 800's push curves are in the extraction, not the profile.
- Grain and halation run in the app's render graph; the bake writes a per-layer dye-amount sigma
  table and copies the halation inputs. Grain is inferred from the Print Grain Index and checked
  on published scans; halation strength sits inside the film-base geometry's bounds.
- Portra 160's plot frame and y ticks disagree by 0.024 D; the profile uses the ticks.
- The paper curves are kept as printed, including up to 0.020 D of roll-off past D-max. The sheet
  does not name its sensitometer's light, so the enlarger is a 3200 K stand-in and lab balance acts
  on a relative scale.
