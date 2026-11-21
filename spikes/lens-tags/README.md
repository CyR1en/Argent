# lens-tags

What the a7 IV's lens correction tags (0x7031 to 0x7037) mean, and what the camera's JPEG and Apple's
decoder do with them (2026-10-07).
Python with numpy, rawpy (used only to read mosaics) and Pillow; run with the project's `.venv` and
`python -I`. CC0 samples choose; corpus frames are evaluation only.

| Script | Does |
| --- | --- |
| `tags.py FILE...` | prints the six tags, lens, crop and sizes |
| `jpeg.py ARW PREFIX` | writes the embedded JPEGs; IFD2's is the camera's corrected full-size rendering |
| `register.py ARW CORRECTED OUT.npz [grid_x grid_y patch reach]` | where a corrected picture (JPEG, or a `.npy` decode from `LensMeasureTests/dump`) puts each patch of an uncorrected bilinear demosaic, per channel; a `.npy` first argument registers two decodes |
| `show.py OUT.npz [mincorr]` | the field by ring, radial and colour parts |
| `fit.py OUT.npz KNOTS [mincorr]` | fits `r (1 + u d(r)) / s`: units, scale, knot reach, centre, interpolation |
| `vignette.py ARW JPEG DKNOTS S VKNOTS` | the JPEG's brightening by ring beside the shading curve under candidate units |
| `ca.py ARW KNOTS32`, `selftest.py ARW` | red and blue against green beside the lateral colour curve; a known injected shift to check registration |
| `baked.py`, `baked2.py`, `comb.py` | look in the raw for a baked-in shading gain (empty codes, noise slope, histogram comb) |
