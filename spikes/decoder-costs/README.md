# decoder-costs

What the in-house path's GPU stages cost once a uint16 Bayer mosaic is in memory. `extract_cfa.py`
writes the lossless L sample's visible mosaic (7028 by 4688) through rawpy, standing in for the tile
decoder. `costs.swift` times representative, untuned Metal kernels, each in its own command buffer
(median of 15 after 3 warm-ups), then the chain in one. `compare.py` checks the demosaic against
Apple's decode of the same file. Kernel quality is not calibrated: the numbers are costs.

    ../../.venv/bin/python extract_cfa.py ../../samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW out/L
    swiftc -O -framework Metal costs.swift -o costs
    ./costs out/L --iters 15 --dump out/L
    ../../.venv/bin/python compare.py out/L.demosaic.rgba16f 7028 4688 12 8 APPLE.f32 out/compare.png

`APPLE.f32` is Apple's pinned decode with lens correction and NR off, float32 RGBA after an 8-byte
width and height header, as the decoder probes write it.

Result (2026-10-06): normalize 2.0 ms; demosaic 4.3 (bilinear), 5.1 (Malvar-He-Cutler), 10.0 ms
(Hamilton-Adams, two passes); NR 27 ms as a five-level decimated Laplacian pyramid against 76 to 110
ms for a full-resolution a-trous wavelet and 233 ms for non-local means; lens 5.2 (bilinear) to 14.5
ms (Catmull-Rom); the chain 53 ms. The demosaic matched Apple's to 0.044 stops median after a 3 by 3
colour fit.
