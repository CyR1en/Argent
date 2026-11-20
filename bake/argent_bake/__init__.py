"""Argent bake tool.

Turns a stock profile (spectral sensitivities, characteristic curves, the sheet's
density spectra, couplers) into the two 3D LUTs the app applies per frame: the
Negative LUT (log exposure to dye amounts) and the Print LUT (dye amounts to
display-linear RGB). See the spec, Architecture and rendering pipeline.

The film library uses Kodak and Fujifilm datasheets, an explicitly marked ColorPlus
proxy, and the Endura Premier paper. The manifest and LUT files match the Swift side.
"""

__version__ = "0.5.0"
