# Licences of the bundled models: the four mask models and Remove's

Every conversion script copies this folder beside its output (`build/models/licences/`), and `scripts/build-app.sh`
clones it into `Argent.app/Contents/Resources/Models/Licences/`, so the texts travel wherever the models do. Argent's
source is open (Apache-2.0, since 2026-11-19), but no model weights are in Git or in any published build: whoever runs
the conversion scripts downloads the weights under the terms below and is bound by them. None of the texts asks anything
of a copy kept on its builder's Mac beyond their use clauses. **Before an app with the models, or a model file, goes to
anyone else, ask counsel** (P0-S5 section 3.7); `scripts/build-dmg.sh --no-models` builds an image without them. This is a record of what the texts say, not legal advice.

**Decision 24, plainly:** S3OD-sod and ViTMatte-S are used here for the owner's personal, non-commercial use only.
**These weights must not be sold or distributed unless their terms are cleared or the models are replaced.**

| Model | Part | Text here | What applies |
| --- | --- | --- | --- |
| Depth Anything 3 Mono-Large (`da3-sky-sq756-f16`) | code (ByteDance-Seed/Depth-Anything-3 at `3d835ec1`) and weights (`depth-anything/DA3MONO-LARGE` at `f465978e`) | `DA3-LICENSE` (the source tree's own `LICENSE`, copied at conversion) | Apache-2.0, as the model card and the repository say: keep the licence and notices with any copy |
| EoMT-DINOv3-L (`eomt-sq768-f16`) | EoMT code (tue-mps/eomt) | `EoMT-LICENSE-MIT.txt` | MIT, Copyright (c) 2025 Mobile Perception Systems Lab at TU/e: the notice goes with any copy |
| | weights (`tue-mps/eomt-dinov3-ade-semantic-large-512` at `1d1f1727`) | `DINOv3-LICENSE.md` | The card says `license: mit`, but the file holds DINOv3 ViT-L/16 weights fine-tuned, so Meta's DINOv3 Agreement applies to them: a copy of it with any distribution (1.b.i), no reverse engineering (1.b.iv), trade controls and no military use (1.b.iii, 1.b.v), Meta may amend it |
| | training data (ADE20K) | `ADE20K-terms.txt` | Images: non-commercial research and educational use; the label names (annotations) BSD-3-Clause, Copyright 2019 MIT CSAIL. Whether the image terms reach a model trained on them, the text does not say: a question for counsel before any sale |
| S3OD-sod (`s3od-sod-sq1024-f16`) | code (KupynOrest/s3od at `11385423`) | `S3OD-LICENSE-MIT.txt` | MIT, Copyright (c) 2024 S3OD Team: the notice goes with any copy |
| | weights (`okupyn/s3od-sod` at `3752fc7f`) | `S3OD-sod-model-card.md`, `DINOv3-LICENSE.md` | The card is 24 bytes, `license: mit`, with no LICENSE file; the checkpoint's encoder has DINOv3-B's structure, so that the weights are a DINOv3 derivative is inference, and Meta's Agreement is carried as for EoMT |
| | training data (FLUX.1 Krea-dev images, DIS5K, HR-SOD, UHRSOD, DUTS) | `FLUX1-Krea-dev-LICENSE.md` | The FLUX.1 [dev] Non-Commercial License binds whoever generated the images. Its section 4(a) bars using data it produced for commercial or production purposes; whether that reaches a model trained on them, the text does not say. The real-data sets' terms were not read: a question for counsel before any sale |
| ObjectClear (`objectclear-unet`, `-object-encoder`, `-vae-encoder`, `-vae-decoder`, and the text states), Remove's model | code (zjx0101/ObjectClear at `c052d91e`) and weights (`jixin0101/ObjectClear` at `c73af808`) | `ObjectClear-LICENSE-S-Lab-1.0.txt` | NTU S-Lab License 1.0: use and redistribution for non-commercial purposes only, the notice with any copy. The terms of what it was trained from (an SDXL inpainting UNet and VAE, a CLIP image encoder) were not read here. Personal use on the owner's Mac, never distributed, by the rule of decision 24 (docs/remove-plan.md, section 4.5) |
| ViTMatte-S, Composition-1k (`vitmatte-s-c1k-sq1024-f16`) | code (hustvl/ViTMatte at `8cd7ef06`) | `ViTMatte-LICENSE-MIT.txt` | MIT: the notice goes with any copy |
| | weights (`hustvl/vitmatte-small-composition-1k` at `6a58ad76`) | `ViTMatte-S-Composition1k-model-card.md` | The Hugging Face card is tagged `apache-2.0`, written by Hugging Face's team, with no LICENSE file in the model repository: the weaker kind of evidence |
| | training data (Composition-1k, Adobe's Deep Image Matting set) | none here | Distributed for research; its terms were not read and would bind the weights as the academic sets do for every other model here: a question for counsel before any sale |

Sources: P0-S5's `licence/` folder (fetched 2026-11-06, the EoMT and ADE20K texts through R3); the DA3 source tarball
the recipe pins by SHA-256; research task V4's `licence/` (S3OD's MIT at the pinned commit, the HF card, the DINOv3
Agreement's ViT-B copy, which is byte-identical to the one here, and FLUX.1 Krea-dev's licence at its HF revision); and
research task Y2's `licence/` (ViTMatte's LICENSE at the pinned commit and the HF card). The weights and the
converted models never go into Git.
