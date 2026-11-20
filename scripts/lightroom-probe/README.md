# Lightroom slider probe

The tools behind [Lightroom's Light controls, measured](../../docs/research/lightroom-sliders.md):
renders of one raw by Lightroom Classic at each Basic-panel tone value, the output-L* targets
fitted from them (`Sources/ArgentCore/Film/LightroomToneTargets.swift`), the tone base field's
constants, and a scorecard of how close Argent's controls come. The data stay out of Git, under
`references/lightroom-probe/` (Lightroom's exports, the raw clones, caches, reports, renders);
Lightroom Classic is the owner's own copy, driven only through the plug-in's job folder and its one menu
command, never its interface otherwise. `SESSION.md` says how the mask session ran with no one at the keyboard, at the owner's
explicit request; `jobs.py run` presses the menu command for settings jobs (below, "The Presence probe").

| Tool | What it does |
| --- | --- |
| `probe.py` | Shared code: reading Lightroom's ProPhoto exports and the spike's sRGB TIFFs, CIE L*, the tone base field (the same math as `ToneBaseField`, luminance averaged in linear light, and the gain-table compilers' constants, which the fit, the scorecard and the job analysis read), a render's monotone transfer from scene stops to output L*, the gain-on-base fit, running `argent-spike`. |
| `make_charts.py chart\|locality\|adaptation\|masks\|raws OUT [RAW]` | The 2400 × 1600 TIFF chart (ramp, checkerboard, patches); the 3000 × 2400 linear DNG locality chart (a ramp, and squares 8 to 512 pixels on dark, mid and bright surrounds); six 3000 × 2000 DNG adaptation charts (one ramp over six contents), which Lightroom renders as raws; the mask session's three DNG charts (`masks`: a 2000 × 1200 ramp, a 1600 × 1000 flat field and its half-size twin); or raw clones with XMP sidecars, one per variant. |
| `jobs.py status\|variants\|combos\|auto\|masks\|dump\|run` | Writes jobs for the plug-in: every probe variant of a file (the Presence controls too), or listed combinations of settings, each rendering a clone of the file in `inputs/<job>/`, exported to `exports-<job>/`; a camera raw's clone gets the probe's neutral XMP sidecar; `masks` writes the mask session (below); `dump` asks the plug-in to write out the mask table Lightroom holds for some photos. Refuses unless the jobs folder holds `READY`, except `masks --jobs DIR` (a dry run elsewhere). `run` presses the menu command and waits for every `.done`. |
| `ArgentProbe.lrplugin/`, `install-plugin.sh` | The Lightroom Classic plug-in (version 1.2.0) and its installer, which points it at this checkout's `references/lightroom-probe/jobs`, backs up the plug-in it replaces (`--restore` puts it back) and can declare another SDK version (`--sdk 13`). Lightroom loads it at its next launch. |
| `fit_targets.py` | The fit: global and local targets from the exports, the base field's radius and epsilon by sweep, the generated Swift file and `fit/report.json`. About 4 minutes. |
| `analyze_jobs.py adaptation\|locality\|scenes\|combos\|range` | What the plug-in's jobs show: the ramp over six contents, the squares, three more scenes against the targets, composition and Exposure, and a range weight on the base. |
| `score.py [--manual-version V] [--spike BIN] [--label NAME]` | The scorecard: renders the probe raw through `argent-spike --auto` at every measured value for Portra 400 and Ektar 100 and compares each control's change of L* with Lightroom's. Writes `score/<label>/scorecard.md` and `.json`. About 2 minutes. |
| `sheets.py BEFORE AFTER [--crops] [--full]` | Comparison sheets: two scorecards' renders beside Lightroom's, each control at its extremes, with crops at the scorecard's pixels (`--crops`) or the raw's own (`--full`, rendered whole with each compiler). Writes `score/<AFTER>/sheets/`. |
| `scene_io.py` | The film render's input and output as arrays (below): the scene it receives, the print of a changed scene, and both sides in CIE XYZ under D50. |

Run Python with the repository's `.venv` and `-I` (numpy only; the exports are data, not code):

```sh
swift build -c release --product argent-spike
.venv/bin/python -I scripts/lightroom-probe/fit_targets.py
.venv/bin/python -I scripts/lightroom-probe/score.py --manual-version 2026-10-09-1 --label before-2026-10-09-1
.venv/bin/python -I scripts/lightroom-probe/score.py --manual-version 2026-10-29-1 --label after
.venv/bin/python -I scripts/lightroom-probe/sheets.py before-2026-10-09-1 after --crops
```

`score.py` runs unchanged on any branch with this spike's flags; `--spike` points it at another
checkout's build. Its renders set one control each, so `2026-10-29-1` and `2026-11-06-1` score the same
bytes; what separates them, Exposure with Highlights or Shadows, is in
[the sliders note](../../docs/research/lightroom-sliders.md#12-highlights-and-shadows-read-the-base-before-exposure-2026-11-06).

## The render as arrays

Three spike flags take the image out of the film render and put a changed one back in, so a stage can be prototyped
in Python and tested through the real film chain. They need `--stock` and one raw file. Each array is a NumPy `.npy`,
little-endian float32 in C order, shape (height, width, 3), top row first:

- `--scene-out FILE`: the decode as `FilmRenderer.render` receives it. Scene-linear light in linear Rec. 2020
  primaries with a D65 white, middle gray 0.18, unclipped.
- `--scene-in FILE`: FILE's array rendered in place of the decode. It must have the decode's size, or the spike
  stops and names both sizes. It is rounded to half floats, as the decode is held.
- `--print-out FILE`: the render's result before the resize and the encode. Display-linear light in linear
  Rec. 2020 primaries with a D65 white, 1 the display's white. The spike's picture is this converted to sRGB.

```python
import scene_io  # with scripts/lightroom-probe on sys.path
flags = ("--auto", "--tiff", "--no-lens", "--long-edge", 1752)   # as score.py renders
scene = scene_io.scene_of(raw, stock, *flags)
p = scene_io.print_of(raw, stock, my_stage(scene), *flags)
dY = scene_io.print_xyz(p)[..., 1] - scene_io.lightroom_xyz(export)[..., 1]
```

`print_xyz` takes the print to CIE XYZ under D50 with Bradford. `lightroom_xyz` reads an export with its own
profile's gamma and colorants. Both land in the ICC connection space, white Y = 1, so the print and Lightroom's
ProPhoto export compare without the sRGB clip of the spike's TIFF.

What holds, measured on the probe raw with Portra 400:

- A scene out and back in gives a bit-identical print and a byte-identical TIFF, and the TIFF equals one made
  without the flags.
- `--long-edge` resizes only the picture, so the arrays stay at the decode's 7008 x 4672, 393 MB each. There each
  flag adds 110 to 140 ms, the median of five runs, and 0.2 GB of peak memory; `--scene-in` adds 0.55 GB, as its
  file is mapped. `--scale 0.25` decodes at 1752 x 1168, 25 MB and 9 ms an array, but a smaller decode is not the
  scorecard's render. A 4 x 4 mean of the full-size print, clipped to sRGB, gives `score.py`'s L* of the
  `--long-edge 1752` TIFF within 0.015.
- The scene doubled renders the same bytes as `--exposure-ev 1` without `--auto`. With `--auto` it prints a median
  2.9 L* darker, most where the local base is near middle gray. Auto's tone step reads its base from the scene
  before Exposure (`PrintToneShaders.swift`), so the doubled scene's base is a stop higher. Every base field (the
  tone step, Highlights and Shadows, halation) is made from the scene the render is given, while `--auto`'s aim
  still comes from the raw's own decode. A stage tried through `--scene-in` therefore acts before every base field.

## The Presence probe (2026-11-11)

Lightroom's renders for Texture, Clarity, Dehaze, Vibrance and Saturation: 523 renders of the probe raw, 20 charts and ten
photographs, with no one at the keyboard. The smoke test, the manifest and the chart layouts are in the Presence research
folder (`~/Documents/ArgentResearch/presence-20261111.noindex/probe/`); the data are `references/lightroom-probe/p-charts/`,
`inputs/p-*` and `exports-p-*`.

| Tool | What it does |
| --- | --- |
| `lr_menu.swift` | Presses "Argent Probe: run pending jobs" through accessibility on Lightroom's pid, nothing else. Lightroom shows its full menu bar only while it is in front, so it also sets Lightroom frontmost (an accessibility attribute, not a click). Compiled by `jobs.py run`, which must run in a session that has Accessibility. |
| `presence_charts.py`, `make_charts.py presence OUT [LAYOUTS]` | The 20 charts and their layouts: gratings at four mean levels and a half-size twin, steps and their twin, colour gratings and noise, a flat field, flats and a ramp, synthetic haze with three airlights, the locality chart and its twin, the colour grid (DNG and TIFF), and a composite for the combinations. Each layout gives every region's pixel box and ground truth. |
| `presence_plan.py list\|write JOB...\|manifest OUT [--round N]` | Each round's jobs (round 1: 32 jobs, 523 renders, 73 GB), writing them (names or shell patterns), and the manifest: every export read back, the settings Lightroom applied (from the export's own XMP) and its size, statistics and a sanity verdict per control and source, and each base against any other render of it. |
| `presence_stats.py EXPORT...` | Reads an export's applied settings and look, and the statistics each control should move: fine and local log detail, the dark channel, chroma, the mean change from the base, and the pixels clipped at either end. |
| `test_presence.py` | `python -I -m pytest -q scripts/lightroom-probe/test_presence.py`: the charts against their layouts, the jobs, the statistics and the plan. About 10 seconds. |

```sh
P=scripts/lightroom-probe; touch references/lightroom-probe/jobs/READY
.venv/bin/python -I $P/make_charts.py presence references/lightroom-probe/p-charts LAYOUTS
.venv/bin/python -I $P/presence_plan.py write p-raw && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py manifest OUT
rm references/lightroom-probe/jobs/READY
```

Round 2 (prefix `q-`, the same afternoon) renders the fit agent's three requests (`q-tone-*`: Clarity's frame
adaptation, one grating at four levels and alone on dark, bright and ramp frames; `q-edge`: detail beside a 3-stop edge;
`q-combo`, `q-raw`, `q-grating-0`: Texture +100 with Clarity +100) and twenty more photographs at Clarity +-50 and +-100
and Texture +-100. `frames` chose the photographs: it measures every candidate's quick decode (median, spread, fine and
coarse detail) and takes, one frame a scene, the one farthest from round 1's photographs and from those already taken.
Its manifest goes to the research folder's `probe/round2/`, beside round 1's, which it does not touch.

```sh
P=scripts/lightroom-probe; R2=~/Documents/ArgentResearch/presence-20261111.noindex/probe/round2
.venv/bin/python -I $P/presence_plan.py frames $R2
.venv/bin/python -I $P/make_charts.py presence references/lightroom-probe/q-charts --prefix q-
.venv/bin/python -I $P/presence_plan.py write --round 2 all && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py manifest $R2 --round 2
```

What the run found about driving Lightroom (plug-in 1.1.0, Lightroom Classic 15.6, measured):

- A raw imported with no sidecar gets the Adobe Color look, and the plug-in's `CameraProfile` key does not remove it. The
  neutral sidecar does: the base render is then the 2026-10-29 probe's to the bit, and so are Exposure +1 and Highlights -100.
- Every press of the menu item took on the first try (7 of 7 runs), once Lightroom was in front. The background poll
  does not run while Lightroom is in the background, but it does while it is in front: an eighth job started 2 s after
  Lightroom came forward, before the press. `jobs.py run` counts either as the start.
- Lightroom's accessibility tree degrades over a session (`AXWindows` returns the application element once per window),
  so `lr_menu windows` reads the window server to watch for a dialog.
- 1.3 to 1.5 s per full-size raw render from the press to the `.done` (5 runs), most of it the import; a chart render is faster.
- Round 2 (five runs): the poll took the first job by itself 1 s after it was written, with Lightroom in the background;
  the other four needed the press, which took on the first try each time. `run` reads a job from its `.processed` file
  if the poll got there first, and presses only if nothing has started.
- Lightroom's render of the same raw and sidecar changed a little between round 1 and round 2 (mean 0.70 codes, most in
  the darks) but was bit-identical within round 2: compare each render with a base from its own session.

Round 3 (prefix `r-`) renders the Dehaze fit's four requests (`r-haze-neutral`: the slider's ten values on the neutral
haze chart; `r-haze-*-crop`: a crop through Lightroom's crop keys; `r-sky-standard` and `r-sky-matrix`: the sky photograph
under Adobe Standard and through a matrix alone; `r-haze-white`: a white patch brighter than the haze), the colour fit's
three (`r-colour-grid`: Exposure beside Saturation and Vibrance; `r-colour-grid-tif`: Vibrance's ten values) and round
2's twenty frames at Dehaze -100, +50, +100, Vibrance -100, +50, +100 and Saturation -100, +100 (`r-photo-*`), held out
from those fits. Every job carries its own base. `r-end-*` render two bases again in a later run, `r-again-*` render
Dehaze twice in one job on three charts and two photographs, and the manifest compares each with the other renders of
the same source and settings, to the code. `r-sky-matrix` is not a synthetic
chart: it is the photograph decoded by the main checkout's spike and written as a LinearRaw DNG
(`presence_charts.sky_matrix`), because every profile Lightroom ships for the a7 IV carries a look table.

```sh
P=scripts/lightroom-probe; R3=~/Documents/ArgentResearch/presence-20261111.noindex/probe/round3
.venv/bin/python -I $P/make_charts.py presence references/lightroom-probe/r-charts --prefix r-
.venv/bin/python -I $P/presence_plan.py write --round 3 'r-crop-flag-*' && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py write --round 3 r-haze-neutral r-haze-neutral-crop r-haze-two r-haze-two-crop \
    r-sky-standard r-sky-matrix r-haze-white r-colour-grid r-colour-grid-tif && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py write --round 3 'r-photo-*' && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py write --round 3 'r-end-*' && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py write --round 3 'r-again-haze-*' && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py write --round 3 'r-again-photo-*' && .venv/bin/python -I $P/jobs.py run
.venv/bin/python -I $P/presence_plan.py manifest $R3 --round 3
```

What round 3 found about driving Lightroom (plug-in 1.1.0, measured):

- A crop goes through the plug-in's settings keys: `CropLeft`, `CropRight`, `CropTop` and `CropBottom` as fractions take,
  with `HasCrop` spelt `true`, `1` or left out (Lightroom writes `HasCrop="True"` itself). The export is the crop of the
  uncropped render to the code.
- The first run's jobs were taken by the plug-in's poll 2 s after they were written, with Lightroom in the background;
  the other five runs needed the press, which took on the first try each time.
- Every base asked twice came out identical, within the session (11:58 to 12:21) and against rounds 1 and 2, and so
  did every Vibrance and Saturation render and every Dehaze render of a photograph asked twice. Dehaze's renders of the
  synthetic haze charts did not: the same settings, twice in one job, land on one of a few outcomes a few codes apart
  (tens on `r-haze-white`). `r-again-*` measure that, and the manifest compares every render with any other of the
  same source and settings.

## The data

- `raw/raw_NN_<control>_<value>.ARW`: 37 clones of
  `samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW` (`make_charts.py raws`).
- `exports/raw_*.tif`: Lightroom Classic 15.6's renders of them, process version 15.4, Adobe
  Standard, sharpening and noise reduction off, lens profile off, linear point curve: uncompressed
  16-bit ProPhoto RGB, pure gamma 461/256, 7008 × 4672.
- `exports-charts/chart_*.tif`: the TIFF chart through the plug-in. Lightroom ignored the settings
  embedded in the TIFFs themselves (`exports/chart_*.tif` all equal the base).

## The plug-in

A job is `<name>.job` in the jobs folder: an `OUT` line and `ITEM` lines (`Probe.lua` has the
format). The plug-in imports each photo, applies neutral settings and the item's own, exports a TIFF
named after the photo, renames the job `.processed` and writes `.done`. On 2026-10-29 its background
poll did not pick up a job by itself; **Library > Plug-in Extras > Argent Probe: run pending jobs**
did. Write jobs only when the folder holds `READY`, which the owner or coordinator creates while
Lightroom runs the plug-in.

A job whose first line is `MODE<TAB>auto` (`jobs.py auto NAME LIST`, plug-in 1.1.0) runs Lightroom's own Auto
instead of the item's settings: each photo starts from neutral, `LrDevelopController.setAutoTone()` runs in the
Develop module, and the sliders go to `exports-NAME/auto.tsv` as they are read. Every 13th photo runs Auto again
(`auto-repeat.tsv`), then every photo is exported at a 2000-pixel long edge with Auto (`auto/`) and back at neutral
(`neutral/`). Lightroom must stay in front while it runs. The statistics-based Auto Tone from before 2018 is not
reachable through the SDK.

The plug-in sets no camera profile or look. Its raw renders came out with Lightroom's default
**Adobe Color** look over Adobe Standard, unlike the probe's sidecar renders. Compare a job's
renders with its own base, or map the look out as `analyze_jobs.py combos` does.

The jobs run on 2026-10-29 (196 renders), as written:

```sh
P=scripts/lightroom-probe; R=references/lightroom-probe; C=references/corpus/imaging-resource-a7iv-gallery
py() { .venv/bin/python -I "$@"; }
py $P/make_charts.py locality $R/charts-dng; py $P/make_charts.py adaptation $R/charts-dng
py $P/jobs.py variants locality $R/charts-dng/locality.dng --controls highlights,shadows,whites,blacks,contrast
for c in dark mid bright white split texture; do
    py $P/jobs.py variants adapt-$c $R/charts-dng/adapt-$c.dng --controls highlights,shadows,whites,blacks,contrast \
        --values -100,100
done
for f in Y-JG-SONY-A7-IV-0602 Y-JG-SONY-A7-IV-1455 Y-JG-SONY-A7-IV-0255; do
    py $P/jobs.py variants scene-$f $C/$f.ARW --controls highlights,shadows,whites,blacks,contrast --values -100,-50,50,100
done
py $P/jobs.py combos combos $R/raw/raw_00_base.ARW \
    'hl-100_sh+100:Highlights2012=-100;Shadows2012=100' 'hl+100_sh-100:Highlights2012=100;Shadows2012=-100' \
    'wh+50_bl-50:Whites2012=50;Blacks2012=-50' 'wh-50_bl+50:Whites2012=-50;Blacks2012=50' \
    'co+50_wh+50:Contrast2012=50;Whites2012=50' 'co+50_bl-50:Contrast2012=50;Blacks2012=-50' \
    'co+50_hl-50:Contrast2012=50;Highlights2012=-50' 'co-50_sh+50:Contrast2012=-50;Shadows2012=50' \
    'ex-1_hl-100:Exposure2012=-1;Highlights2012=-100' 'ex+1_hl-100:Exposure2012=1;Highlights2012=-100' \
    'ex-1_sh+100:Exposure2012=-1;Shadows2012=100' 'ex+1_sh+100:Exposure2012=1;Shadows2012=100' \
    'ex-1_wh+100:Exposure2012=-1;Whites2012=100' 'ex+1_bl-100:Exposure2012=1;Blacks2012=-100'
```

## L2: AI masks through the plug-in

`MODE masks-ai` (plug-in 1.3.0) asks Lightroom for Sky and Subject masks through the SDK (`createNewMask('aiSelection', …)`, polled until one
new mask has stayed for a second), then exports each photo from Library: for each of two local Exposures `masked-e…` and its full-coverage series `full-e…`, then `base`.
`ai_masks.py` writes the job and recovers each mask from its exports by inverting the full-coverage series; `SESSION.md`, "L2", says how it was
run, with the network and the owner's catalog denied by the sandbox.

## The mask session (Phase 0 of the masking plan)

One session at Lightroom Classic with the owner present, table jobs only (no AI mask, no pointer gesture), settles what Argent's
mask arithmetic should copy before Phase 1 freezes it: partial coverage (slider or gain), how masks overlap, Amount, the feather
profile, the algebra of components, the base, local with global, and the range of local Exposure. **`SESSION.md` is the owner's
script**, `session-masks.sh` the terminal steps around it.

| Tool | What it does |
| --- | --- |
| `SESSION.md` | The script, from the first click to the last, with a time per step, what to watch, what not to do, every alert Lightroom might raise, and what to do if it refuses a table. |
| `session-masks.sh plan\|prepare\|status\|stop\|check\|analyze\|finish\|clean` | `prepare` (Lightroom quit) makes the charts, installs the plug-in, creates `READY` and writes the jobs; `status`, `stop` and `check` follow the run; `analyze` writes the report; `finish` takes `READY` away and restores the old plug-in. |
| `masks_plan.py` | The catalogue of experiments: 353 items in six jobs, plus `m06-confirm` (88) and `m07-law` (29) added after the first run, ordered by importance (`m00-smoke` is a go/no-go that stops the run if Lightroom does not take a table), each tied to its question, with the time estimate. Writes the job files, the mask tables (JSON in Lightroom's own field names) and `masks-plan.json`. |
| `analyze_masks.py check\|all\|q1...q8` | Reads the exports and answers the eight questions in numbers against Argent's candidate rule (R5's arithmetic, R8's constants), with the rule to adopt and the L* cost of keeping the current one. |
| `mask_models.py` | The numerics both the analysis and its tests share: monotone interpolation, the inversion of Exposure's response, the candidate laws, and R5's arithmetic driven by tables built from Lightroom's own whole-frame renders. |
| `synth_masks.py` | A made-up Lightroom with laws we choose, rendering the whole plan to TIFFs in Lightroom's export format; the only test of the analysis possible before the session. |
| `test_masks.py` | `python -I -m pytest -q scripts/lightroom-probe/test_masks.py`: plan, job files, the plug-in's Lua (in a Lua 5.1: micro's embedded interpreter) and its runner against a fake Lightroom, and the analysis against known laws and against each law flipped. About 2 minutes. |
| `lua-tests/` | The Lua halves of those tests. |
| `r5-parity/` | Compiles R5's own `SceneCPU` (from the masking research's evidence) and checks the Python port of its arithmetic against it. |

The plug-in's `MODE masks` jobs (`MaskJob.lua`, `Probe.lua`) apply a `MaskGroupBasedCorrections` table with `photo:applyDevelopSettings`
(the field names are ExifTool's table of Adobe's crs schema; what they mean was measured by third parties on 15.6), check the
table against the hazards found by others (colour ranges with two samples crash Lightroom; unknown fields and incomplete
components vanish without a word), read it back and log what Lightroom kept (`WARN` for a lost component, `NOTE` for a
changed scalar), export, and take the tables off the photos again. They run only from the menu command, only in a catalog
whose name contains `argent-masks-session`, and stop at a `STOP` file in the jobs folder.
