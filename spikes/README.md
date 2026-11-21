# Spikes

Measurement prototypes kept so their results can be re-run after a macOS or toolchain update. None
of this is part of the package or the app: `swift build` does not see it, nothing here has tests, and
none of it is hardened against bad input. Numbers are from the project's M4 (2026-10-05 to
2026-10-07); they describe the prototypes and toolchains tested then, not current app performance.

| Folder | What it is | Fed |
| --- | --- | --- |
| [`lossless-decode/`](lossless-decode/) | LibRaw stage timings and a from-spec tile-parallel lossless-JPEG decoder for lossless L, bit-exact with LibRaw | the in-house tile decoder |
| [`decoder-costs/`](decoder-costs/) | Untuned Metal kernels for normalize, demosaic, noise reduction and lens correction on the lossless L mosaic | the decimated-pyramid NR choice |
| [`decoder-probes/`](decoder-probes/) | Swift probes of Apple's RAW decoder: white balance, ISO series and NR, moire reduction, out-of-range pixels | Apple RAW decoder settings |
| [`lens-tags/`](lens-tags/) | Python measurements of the a7 IV's in-file lens correction tags against the camera's JPEG and Apple's decoder | the distortion correction |
