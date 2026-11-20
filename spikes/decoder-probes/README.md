# decoder-probes

Swift probes of Apple's `CIRAWFilter` (decoder version 8) on a7 IV files. Each pins what
`AppleRawDecoder` pins and varies one thing. Findings: [M1-spikes.md](../../docs/M1-spikes.md);
current pins: [Decoder section 8](../../docs/decoder.md#8-apples-decoder-pins-modes-and-baseline).
Build each with the Command Line Tools (all four compiled 2026-10-06, Swift 6.4, macOS 27.0):

    swiftc -O -framework CoreImage -framework CoreGraphics -framework Metal -framework ImageIO NAME.swift -o NAME

| Probe | Question | Run |
| --- | --- | --- |
| `wbprobe` | What a change of neutral does; which setting is a daylight pin (found: a per-channel gain plus a fixed matrix; pin `neutralChromaticity` D55) | `mkdir -p OUT/dump && ./wbprobe OUT FILE...` (report in `OUT/wbprobe2.json`) |
| `isoseries` | ISO 50's gain; luminance NR removed per amount and ISO (needs the local ISO series in `references/corpus`) | `./isoseries meta\|nr\|nrsweep\|preview FILE...` |
| `moire_probe` | What `moireReductionAmount` changes and costs | `./moire_probe [--scale 1.0] [--no-lens] [--levels 0,0.05,0.5,1] [--time N] FILE` |
| `badpixels_probe` | Where out-of-range pixels come from | `./badpixels_probe [--levels 0,1] [--scale 1.0] FILE...` |

Two of the probes' first readings were corrected by the M1 verifiers: Apple's NR response has no jump
at exactly 1.0 (a knee between 0.75 and 0.8), and moire reduction costs 21 to 30 ms with a default
driven by ISO, not crop. The full-frame lossless S border garbage is Apple's window running past the
valid data. `moire_probe` emits one harmless warning about a constant inferred as `Void`.
