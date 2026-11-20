# scripts

Build, sample fetch, regression gate and measurement kits. `docs/ci-regression.md` explains
the checks; each script's header says what it does. This page covers the one set of files that are
built once and never committed: the smart masks' models.

## The smart masks' models

Sky and the new Subject (docs/masking-plan.md sections 3, 7 and decisions 19 to 24) run four converted models that the app bundles:

| File in `build/models/` | Model | Recipe id | Size |
| --- | --- | --- | --- |
| `da3-sky-sq756-f16.aimodel` | Depth Anything 3 Mono-Large, sky and depth heads, one padded 756 × 756 square, Core AI fp16 | `da3-mono-large-sq756-f16-sky-depth-1` | 668.5 MB |
| `eomt-sq768-f16.aimodel` | EoMT-DINOv3-L, ADE20K-150, water, sky and class maps of one padded 768 × 768 square, Core AI fp16 | `eomt-dinov3-l-ade150-sq768-f16-maps3-1` | 630.9 MB |
| `s3od-sod-sq1024-f16.aimodel` | S3OD-sod, three masks and predicted IoUs of one black-padded 1024 × 1024 square, Core AI fp16 | `s3od-sod-dinov3b-sq1024-f16-masks3-iou-1` | 216.9 MB |
| `vitmatte-s-c1k-sq1024-f16.aimodel` | ViTMatte-S (Composition-1k), the alpha of one 1024 × 1024 tile, Core AI fp16 | `vitmatte-s-c1k-sq1024-f16-alpha-1` | 59.2 MB |

**Build them once, then the app:**

```sh
scripts/convert-da3-sky.zsh        # about 1 minute from nothing: venv, 1.34 GB download, 5 s of conversion
scripts/convert-eomt.zsh           # about 40 s more: the same venv, a 1.26 GB download
scripts/convert-s3od.zsh           # S3OD-sod: the same venv, a 465 MB download, about 3.5 s of conversion
scripts/convert-vitmatte.zsh       # ViTMatte-S: the same venv, a 113 MB download, about 4 s of conversion
scripts/build-app.sh               # clones all four into Argent.app/Contents/Resources/Models with cp -c
```

They need macOS 27 on Apple silicon, Homebrew Python 3.14 (`brew install python@3.14`) and the network
once: PyPI for the 29 packages of `models/requirements.lock` (each pinned by SHA-256, one venv for both),
Hugging Face for the weights and GitHub for DA3's source, each checked against its pinned SHA-256 before
use. The venv, downloads and source go to `build/models/.work/` (about 3.5 GB, safe to delete; set
`MODELS_WORK=DIR` to keep them elsewhere). Nothing of it, and no model, goes into Git: `build/` is ignored.
An existing model is kept; `FORCE=1` builds it again.

**What makes a model the same model.** A conversion is not byte-deterministic: the last ~16 KB of
`main.mlirb` (symbol names) differ every run, so every conversion has a new file SHA-256, and Core AI
compiles a new copy for it. What a model computes is the same, and each script proves it: it runs the new
file on a fixed canary square made from the CC0 sample DSC06673's neutral print
(`models/canary-DSC06673.png`) and fails unless the outputs hash to the pinned value (DA3 `4873a5f8…`,
EoMT `63bdb66c…`, S3OD `03338301…`, ViTMatte `a5d9b787…`). The manifest beside each model records its recipe id, weights SHA-256, canary hash and
`main.mlirb` SHA-256; the app refuses a model whose manifest names another recipe, weights or canary
(`MaskModels.identity(of:)`), and `MaskModelCanaryTests` checks the same hashes from Swift whenever
`build/models` holds both models.

So rebuild only when a recipe changes (a new recipe id) or the files are lost. A rebuilt model gives
existing seeds nothing to fear (seeds are stored, never remade), but the app's next "Preparing masks"
compiles it again and deletes the old compiled copy by its bookmark.

**Without the models** `scripts/build-app.sh` still builds and signs the app, says which model is missing,
Sky reports itself unavailable, and Subject falls back to Vision with today's edge and says why in its row.

**Licences.** The scripts copy `models/licences/` beside the models, and the app bundle carries it in
`Contents/Resources/Models/Licences/`: DA3 is Apache-2.0; EoMT's code is MIT, but its weights are a DINOv3
derivative under Meta's DINOv3 Agreement and were trained on ADE20K (non-commercial research terms for the
images); S3OD-sod's code is MIT and its weights are treated as a DINOv3 derivative, and trained partly on FLUX.1 Krea-dev images;
ViTMatte's code is MIT and its Composition-1k weights rest on Adobe's research data. No weights are in Git or in a published build; whoever runs these
scripts downloads them under these terms. **Decision 24: these weights must not be sold or distributed unless cleared or replaced,** and counsel is to
be asked before any copy goes to anyone else ([models/licences/README.md](models/licences/README.md)).

## Remove's model

ObjectClear as four Core AI graphs and one small file of text states, 5.94 GB, built by a pinned recipe like the mask
models' and run by `argent-remove`, a helper the app starts as its child (`docs/remove-plan.md`, sections
4.5, 14 and 15):

```sh
scripts/convert-objectclear.zsh    # about four minutes with its parity checks; the UNet's conversion peaks at 11.3 GB
scripts/build-app.sh               # builds and signs the helper, and clones the graphs into Argent.app/Contents/Resources/Models
```

Without the graphs the app still builds, and Remove says it has no model.
