#!/usr/bin/env python3
"""Regenerate the app-icon background as a concentric radio-wave pattern.

Draws black concentric rings emanating from a solid centre dot on white
(the classic radio-broadcast motif): the rings are bold near the centre and
fade toward the edges, and a triangular wedge at the bottom is left blank —
matching the reference art. The transparent boombox foreground is then
cropped to its bounding box and scaled to fill the icon, composited on top to
produce icon.png / app_icon_256.png; icon_background.png (the Android
adaptive-icon background) is the bare pattern, and icon_adaptive_foreground.png
is the boombox scaled to sit in the adaptive safe zone (bigger than the raw
source, but with margin so launcher masks don't crop it). icon_foreground.png
stays the untouched source art so re-running is idempotent.

Run from the repo root:  python3 script/make_icon_bg.py
"""
from PIL import Image, ImageDraw

ICON_DIR = "assets/icon"
SIZE = 1024
SS = 4  # supersample factor for anti-aliasing

# Ring pattern -------------------------------------------------------------
CENTRE_Y = 0.46      # centre a touch above the middle (as in the model)
DOT_R = 0.050        # solid centre-dot radius (fraction of canvas)
FIRST = 1.7          # first ring radius as a multiple of the dot radius
SPACING = 0.042      # constant gap between rings (fraction of canvas)
MAX_R = 0.80         # keep drawing until this radius (runs off the canvas)
WEDGE_HALF = 27      # half-angle (deg) of the blank wedge at the bottom
GRAY_IN, GRAY_OUT = 70, 246   # ring shade: already-faded centre → very light edge
FADE_POW = 0.62      # <1 fades faster (stronger dissolve toward the edge)
STROKE_IN, STROKE_OUT = 0.0125, 0.0024  # ring width: wide near centre → thin

# Boombox ------------------------------------------------------------------
FILL = 1.00          # flat icon: boombox fills the whole canvas (width-limited)
FILL_ADAPTIVE = 0.82  # Android adaptive foreground: bigger, but inside the mask


def make_background(size: int) -> Image.Image:
    n = size * SS
    img = Image.new("RGB", (n, n), "white")
    d = ImageDraw.Draw(img)
    cx, cy = n / 2, n * CENTRE_Y

    dot_r = DOT_R * n
    max_r = MAX_R * n
    spacing = SPACING * n
    # PIL angles go clockwise from 3 o'clock; 90° is straight down. Draw the
    # complement of the downward wedge so a blank triangle is left at bottom.
    start, end = 90 + WEDGE_HALF, 450 - WEDGE_HALF

    dot_shade = (GRAY_IN, GRAY_IN, GRAY_IN)  # match the innermost rings (not pure black)
    d.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r], fill=dot_shade)

    # Constant spacing between rings; both the *shade* and the *stroke width*
    # taper with radius, so the circles look like they dissolve toward the edge.
    r = dot_r * FIRST
    while r < max_r:
        t = min(1.0, (r - dot_r) / (max_r - dot_r))  # 0 near centre → 1 at edge
        f = t ** FADE_POW
        g = int(GRAY_IN + (GRAY_OUT - GRAY_IN) * f)
        w = max(1, round((STROKE_IN + (STROKE_OUT - STROKE_IN) * t) * n))
        d.arc([cx - r, cy - r, cx + r, cy + r], start, end,
              fill=(g, g, g), width=w)
        r += spacing

    return img.resize((size, size), Image.LANCZOS)


def boombox(size: int, fill: float) -> Image.Image:
    """Source foreground cropped to the boombox, scaled to `fill` of the canvas,
    centred on a transparent canvas."""
    fg = Image.open(f"{ICON_DIR}/icon_foreground.png").convert("RGBA")
    crop = fg.crop(fg.getbbox())
    scale = min(fill * size / crop.width, fill * size / crop.height)
    w, h = round(crop.width * scale), round(crop.height * scale)
    crop = crop.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(crop, ((size - w) // 2, (size - h) // 2))
    return canvas


def main() -> None:
    bg = make_background(SIZE)
    bg.save(f"{ICON_DIR}/icon_background.png")

    # Android adaptive foreground: enlarged boombox, transparent background.
    boombox(SIZE, FILL_ADAPTIVE).save(f"{ICON_DIR}/icon_adaptive_foreground.png")

    composed = bg.convert("RGBA")
    composed.alpha_composite(boombox(SIZE, FILL))
    composed = composed.convert("RGB")
    composed.save(f"{ICON_DIR}/icon.png")
    composed.resize((256, 256), Image.LANCZOS).save(f"{ICON_DIR}/app_icon_256.png")
    print("wrote icon_background.png, icon_adaptive_foreground.png, "
          "icon.png, app_icon_256.png")


if __name__ == "__main__":
    main()
