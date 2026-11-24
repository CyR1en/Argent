"""Renders the DMG window's background into App/DMG: background.png (640 x 400) and background@2x.png.

A silver print: a pale, warm paper ground (Finder draws the icons' labels in black on any background
image, even in Dark Mode, so the ground must be light), a faint halation glow behind the app, the wordmark
in Didot in a graphite-to-silver gradient, and an amber row of sprocket holes, the banner's accent
(design/social/banner.html), that leads the eye from Argent to Applications. Finder places the two icons over the marks this draws, at the points in
scripts/dmg/settings.py; keep the two in step.

    .venv/bin/python design/dmg/background.py
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "App" / "DMG"
DIDOT = "/System/Library/Fonts/Supplemental/Didot.ttc"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

W, H = 640, 400
APP = (160, 196)  # icon centres, in points; scripts/dmg/settings.py uses the same
APPLICATIONS = (480, 196)
AMBER = (184, 98, 44)
INK = (28, 29, 33)


def mono(size):
    try:
        return ImageFont.truetype(MONO, size)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", size)


def radial(w, h, cx, cy, rx, ry):
    """1 at (cx, cy), falling smoothly to 0 at the ellipse's edge."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2)
    return np.clip(1 - d, 0, 1) ** 1.6


def render(s):
    w, h = W * s, H * s
    y = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    top, bottom = np.array([238, 236, 232], np.float32), np.array([214, 212, 208], np.float32)
    img = np.broadcast_to(top + (bottom - top) * y, (h, w, 3)).copy()

    # Halation behind the app, a cooler sheen behind Applications.
    img += radial(w, h, APP[0] * s, APP[1] * s, 260 * s, 200 * s)[..., None] * np.array([235, 150, 90]) * 0.10
    img += radial(w, h, APPLICATIONS[0] * s, APPLICATIONS[1] * s, 240 * s, 190 * s)[..., None] * np.array([255, 255, 255]) * 0.10

    # Vignette, then grain.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((xx - w / 2) / (w * 0.62)) ** 2 + ((yy - h / 2) / (h * 0.70)) ** 2)
    img *= (1 - 0.10 * np.clip((d - 0.55) / 0.45, 0, 1) ** 2)[..., None]
    rng = np.random.default_rng(1973)
    grain = rng.normal(0, 1, (h // s, w // s)).astype(np.float32)
    grain = np.kron(grain, np.ones((s, s), np.float32))
    img += grain[..., None] * 2.4

    base = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    # Wordmark: Didot in a silver gradient, as on the banner.
    word = ImageFont.truetype(DIDOT, 46 * s, index=0)
    text = "Argent"
    box = draw.textbbox((0, 0), text, font=word, anchor="ls")
    tw = box[2] - box[0]
    x0, base_y = (w - tw) // 2, 70 * s
    mask = Image.new("L", base.size, 0)
    ImageDraw.Draw(mask).text((x0, base_y), text, font=word, fill=255, anchor="ls")
    g = np.interp(
        np.linspace(0, 1, h),
        [0, (base_y + box[1]) / h, (base_y + box[1] * 0.58) / h, (base_y + box[1] * 0.42) / h, base_y / h, 1],
        [46, 46, 92, 150, 58, 58],
    ).astype(np.float32)
    silver = np.repeat(np.repeat(g[:, None, None], w, 1), 3, 2)
    silver_img = Image.fromarray(silver.astype(np.uint8), "RGB").convert("RGBA")
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    shadow.paste((255, 255, 255, 200), (0, 1 * s), mask)
    base = Image.alpha_composite(base, shadow)
    base.paste(silver_img, (0, 0), mask)

    caption = "DRAG TO APPLICATIONS"
    cf = mono(int(8.5 * s))
    spacing = 2.6 * s
    widths = [draw.textlength(c, font=cf) for c in caption]
    total = sum(widths) + spacing * (len(caption) - 1)
    cx = (w - total) / 2
    for c, cw in zip(caption, widths):
        draw.text((cx, 92 * s), c, font=cf, fill=INK + (130,), anchor="lt")
        cx += cw + spacing

    # The sprocket row: rounded holes that brighten toward Applications, then a chevron.
    holes, hw, hh, gap = 9, 7 * s, 8 * s, 6.5 * s
    span = holes * hw + (holes - 1) * gap
    start = (W / 2) * s - span / 2 - 8 * s
    cy = APP[1] * s
    for i in range(holes):
        a = int(45 + 195 * (i / (holes - 1)) ** 1.4)
        x = start + i * (hw + gap)
        draw.rounded_rectangle((x, cy - hh / 2, x + hw, cy + hh / 2), radius=2 * s, fill=AMBER + (a,))
    tip = start + span + 16 * s
    arm = 9 * s
    draw.line(
        [(tip - arm, cy - arm), (tip, cy), (tip - arm, cy + arm)],
        fill=AMBER + (245,), width=int(2.2 * s), joint="curve",
    )

    return Image.alpha_composite(base, layer).convert("RGB")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for s, name in ((1, "background.png"), (2, "background@2x.png")):
        img = render(s)
        img.save(OUT / name, dpi=(72 * s, 72 * s), optimize=True)
        print(OUT / name, img.size)


if __name__ == "__main__":
    main()
