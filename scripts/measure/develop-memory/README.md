# Develop-memory runs

The tools for [Develops started with the frame view open](../../../docs/manual-development-validation.md#develops-started-with-the-frame-view-open-2026-10-16):
the P, S and R runs of each fix revision, on the measuring build. Rebuilt on 2026-10-17 from that
section's descriptions after the originals, kept only in `~/Documents/ArgentResearch`, were lost when
the M4 was reset on 2026-10-16. The evidence (rolls, logs, timelines, pictures) still goes in a dated
root there, `EVIDENCE` below, outside Git.

| Tool | What it does |
| --- | --- |
| `build-measure-app.sh EVIDENCE` | The measuring build: release with the drive hook (`-DDEBUG`), bundle identifier `camera.argent.Argent.m3mem`, the six baked stocks, signed ad hoc and sandboxed; and `argent-drive`. Into `EVIDENCE/build`, with the commit and machine. |
| `make-rolls.py REPOSITORY OUT` | The 30-frame memory roll twice under fresh identities, `mixed-a` and `mixed-b`, and a three-frame `smoke` roll, with their SHA-256 values. Needs `samples/` (`scripts/fetch-samples.sh`) and `references/corpus/photographyblog-a7iv`. |
| `setup.zsh EVIDENCE` | Writes the rolls if missing, fills each roll's disk cache, gives every frame of `mixed-b` the 2026-10-15 Light and Curve edit, and checks frames 11, 14 and 15. |
| `smoke.zsh EVIDENCE` | Tries the tools on the smoke roll. Not a measurement. |
| `fv-runs.zsh`, `fv-stress.zsh`, `r-runs.zsh EVIDENCE` | P (18 develops), S (15, in 12 runs: each S1 run develops twice) and R (6), each run a fresh app; see `lib.zsh`. |
| `set-runs.zsh EVIDENCE [p] [s] [r]` | The sets under the shared app-run lock, then the raws' SHA-256 values. |
| `summarize.py EVIDENCE/logs [p] [s] [r]` | The tables, and the memory and frame view pass rules, for the sets `set-runs.zsh` ran (all three by default); a set's missing table or a develop short fails. |

Order: `scripts/build-app.sh` (it bakes `build/stocks`), `build-measure-app.sh`, `setup.zsh`,
`smoke.zsh`, `set-runs.zsh`, `summarize.py`. The third pass rule, the test suites, is the usual local
gate ([Local tests](../../../docs/ci-regression.md)). `lib.zsh` drives the app through its hook (`Sources/ArgentApp/Automation.swift`), whose replies it
reads from the unified log, and takes `~/Documents/ArgentResearch/.app-run.lock` so one measured app
runs at a time.
