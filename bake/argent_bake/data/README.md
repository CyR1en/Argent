# Spectral data for argent-bake

Tabulated standards data the bake loads through `importlib.resources`. Each file's first comment
line carries its source, fetch date, original SHA-256 and changes.

| File | Content | Source | Terms |
| --- | --- | --- | --- |
| `cie_1931_2deg_cmf_380-780_5nm.csv` | CIE 1931 2 degree colour-matching functions, 81 rows, 380 to 780 nm at 5 nm (selected from the 1 nm table, values unchanged) | CIE 018:2019 Table 6, DOI 10.25039/CIE.DS.xvudnb9b, fetched 2026-10-05 | (c) CIE, CC BY-SA 4.0 |
| `cie_daylight_components_S0S1S2_300-830_5nm.csv` | daylight components S0, S1, S2, 107 rows at 5 nm (values unchanged) | CIE 015:2018 Table 6, DOI 10.25039/CIE.DS.w7zunnny, fetched 2026-10-05 | (c) CIE, CC BY-SA 4.0 |
| `iso5-3_status_a_m_log_spectral_products.csv` | ISO 5-3:1995 Tables 3 (Status A) and 4 (Status M), log10 spectral products at 10 nm with end slopes | ANSI/ISO 5-3:1995 (ANSI/NAPM IT2.18-1996), the scan at law.resource.org, transcribed by hand 2026-10-05 | numbers only; the standard is not included |

D50, D55 and D65 are computed from S0, S1 and S2 with the CIE 15:2004 formula, not copied from
CIE's illuminant tables. The CIE values are bit-identical to the copies in pbrt-v4, Mitsuba 3,
colour-science and CVRL (the Phase 1 spike, `docs/M1-spikes.md`). The ISO 5-3 file was verified twice
against the scanned page, and its Status M column against an independent transcription
(`docs/M1-spikes.md`).
