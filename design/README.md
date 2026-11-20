# Design sources

The app uses the **Negative / Print** icon in [`App/Argent.icon`](../App/Argent.icon), the only
copy of its three SVG layers (`Assets/`) and Composer settings (`icon.json`).
`scripts/build-app.sh` compiles that Icon Composer document into the bundle's `Assets.car` and
`Argent.icns`; it reads nothing here. Edit the app copy to change the shipped icon.

[`icons/opus/2-negative-print`](icons/opus/2-negative-print) keeps the concept's notes: what the
shapes mean and how the layers are set up in Icon Composer (`README.md`), the background gradient
(`background.txt`) and a flat SVG preview (`preview.svg`). Composer supplies the glass rendering the
app uses; the preview is a reference.

The seven other concepts (the `astra` set's Halide, Film Gate, Exposure A and Meniscus, and the
`opus` set's Halide, Halation and Roll), with their SVG layers, previews and assembled documents,
were removed from the tree; they are in `2a6e696`.

[`dmg/background.py`](dmg/background.py) renders the disk image's window background into `App/DMG`
(`background.png` and `@2x`), which `scripts/build-dmg.sh` uses. Run it with `.venv/bin/python` after
changing it; the icon positions it draws around are in `scripts/dmg/settings.py`.
