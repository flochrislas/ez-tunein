#!/usr/bin/env python3
"""Rasterize the app icon (assets/icon/icon.svg) into every PNG the build needs.

The logo is a vector drawing (Inkscape SVG): a red disc with a white music note,
flanked by two red "broadcast" arcs, on a near-black radial-gradient square.
That single file is the *only* source art; everything else in assets/icon/ is
generated here:

  icon.png                     1024² rounded tile (Windows, Android legacy)
  app_icon_256.png             256² rounded tile (Linux GTK window/taskbar +
                               media-session art)
  icon_macos.png               1024² Apple-template tile (rounder + inset)
  icon_background.png          Android adaptive background — the bare gradient,
                               full-bleed square (the launcher masks it)
  icon_adaptive_foreground.png Android adaptive foreground — the logo alone,
                               on transparency, sized to survive launcher masks

The two adaptive halves are derived from the source SVG in memory (see
`_background_svg` / `_foreground_svg`) so there is never a second copy of the
art to keep in sync. That derivation is *id-based* and will fail loudly if the
drawing is restructured — see doc/app-icon.md for the id contract.

Run from the repo root:  python3 script/make_icons.py
Needs Pillow, plus one of rsvg-convert / inkscape / chrome to rasterize.
"""
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw

ICON_DIR = Path("assets/icon")
SOURCE = ICON_DIR / "icon.svg"
SIZE = 1024

# Corner rounding. A hard square reads as dated everywhere the *app* owns the
# icon's shape — which is every desktop; only Android masks for us (and its
# adaptive layers must therefore stay full-bleed squares).
CORNER_RADIUS = 0.12   # Linux/Windows/Android-legacy: subtle, ~Adwaita's tiles
# macOS is stricter: since Big Sur the Dock does no masking and expects Apple's
# template — a squircle-ish tile inset inside the canvas, so every icon in the
# Dock is optically the same size. Full-bleed art sits visibly too large.
MACOS_RADIUS = 0.225   # of the tile (not the canvas)
MACOS_INSET = 0.805    # tile side as a share of the canvas

# Fraction of this image the artwork is scaled to. Android shows only the central
# 72/108 (0.667) of an adaptive icon and reserves 66/108 (0.611) as the safe zone
# — but flutter_launcher_icons wraps the foreground in an `android:inset="16%"`,
# shrinking whatever we hand it to 0.68. Net: the arc tips land at
# 0.96 × 0.983 (logo share of the viewBox) × 0.68 ≈ 0.64 of the icon canvas —
# clear of every launcher mask, and only just outside the safe zone, which merely
# governs parallax during launcher animations.
FILL_ADAPTIVE = 0.96

SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)
ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")
ET.register_namespace("svg", SVG_NS)

# Ids the derivation depends on (all from the Inkscape source).
BACKGROUND_LAYER = "layer5"   # the full-bleed gradient rect
RING = "path8-4"              # the stroked circle the two arcs are cut from
MASK_BARS = ("rect27", "rect27-0")  # black bars that hide the ring's top/bottom


def _tag(name: str) -> str:
    return f"{{{SVG_NS}}}{name}"


def _find_by_id(root: ET.Element, wanted: str) -> ET.Element:
    for el in root.iter():
        if el.get("id") == wanted:
            return el
    raise SystemExit(
        f"{SOURCE}: no element with id={wanted!r}. The drawing was restructured "
        "— see the id contract in doc/app-icon.md."
    )


def _parent_of(root: ET.Element, child: ET.Element) -> ET.Element:
    for el in root.iter():
        if child in list(el):
            return el
    raise SystemExit(f"{SOURCE}: element {child.get('id')!r} has no parent")


def _load() -> ET.Element:
    return ET.parse(SOURCE).getroot()


def _background_svg() -> ET.Element:
    """Source with every layer but the gradient background dropped."""
    root = _load()
    keep = _find_by_id(root, BACKGROUND_LAYER)
    for group in list(root):
        if group.tag == _tag("g") and group is not keep:
            root.remove(group)
    return root


def _foreground_svg() -> ET.Element:
    """Source with the background dropped and the ring's black masking bars
    replaced by a clip — so the two arcs survive on transparency."""
    root = _load()
    root.remove(_find_by_id(root, BACKGROUND_LAYER))

    # The bars are opaque black rects that only ever cover the ring's top and
    # bottom; clipping the ring to the band between them is exactly equivalent
    # and leaves no black where the background used to be.
    bars = [_find_by_id(root, i) for i in MASK_BARS]
    top = min(float(b.get("y")) + float(b.get("height")) for b in bars)
    bottom = max(float(b.get("y")) for b in bars)
    if not top < bottom:
        raise SystemExit(f"{SOURCE}: masking bars {MASK_BARS} do not leave a band")

    for bar in bars:
        _parent_of(root, bar).remove(bar)

    defs = root.find(_tag("defs"))
    if defs is None:
        defs = ET.SubElement(root, _tag("defs"))
    clip = ET.SubElement(defs, _tag("clipPath"), {"id": "ringBand",
                                                 "clipPathUnits": "userSpaceOnUse"})
    ET.SubElement(clip, _tag("rect"), {
        "x": "-100", "y": f"{top}", "width": "400", "height": f"{bottom - top}",
    })
    _find_by_id(root, RING).set("clip-path", "url(#ringBand)")
    return root


def _rasterize(svg: Path, out: Path, px: int) -> None:
    """SVG → PNG at px², alpha preserved. Uses whatever renderer is installed."""
    if shutil.which("rsvg-convert"):
        cmd = ["rsvg-convert", "-w", str(px), "-h", str(px), "-o", str(out), str(svg)]
    elif shutil.which("inkscape"):
        cmd = ["inkscape", f"--export-width={px}", f"--export-height={px}",
               f"--export-filename={out}", str(svg)]
    else:
        chrome = next((c for c in ("google-chrome", "chromium", "chromium-browser")
                       if shutil.which(c)), None)
        if not chrome:
            raise SystemExit("need one of rsvg-convert / inkscape / chrome to "
                             "rasterize the SVG (apt install librsvg2-bin)")
        # Chrome renders an SVG <img> at its natural size, so wrap it in a page
        # that scales it to the window; the transparent default background keeps
        # the alpha channel intact.
        wrapper = svg.with_suffix(".html")
        wrapper.write_text(
            "<html><head><style>html,body{margin:0;padding:0;"
            "background:transparent}img{display:block;width:%dpx;height:%dpx}"
            "</style></head><body><img src='%s'></body></html>"
            % (px, px, svg.resolve().as_uri())
        )
        cmd = [chrome, "--headless", "--disable-gpu", "--no-sandbox",
               "--hide-scrollbars", "--force-device-scale-factor=1",
               f"--window-size={px},{px}", "--default-background-color=00000000",
               f"--screenshot={out}", wrapper.resolve().as_uri()]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)


def rounded_tile(img: Image.Image, radius: float, inset: float = 1.0) -> Image.Image:
    """Round the flat icon's corners, leaving the outside transparent. `inset`
    shrinks the tile within the canvas (Apple's template); `radius` is a
    fraction of the *tile*, so it stays the same curve whatever the inset."""
    side = round(img.width * inset)
    tile = img.resize((side, side), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (side, side), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, side - 1, side - 1], radius=round(side * radius), fill=255)
    tile.putalpha(mask)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.alpha_composite(tile, ((img.width - side) // 2, (img.height - side) // 2))
    return out


def render(root: ET.Element, px: int, name: str, tmp: Path) -> Image.Image:
    svg = tmp / f"{name}.svg"
    png = tmp / f"{name}.png"
    ET.ElementTree(root).write(svg, encoding="utf-8", xml_declaration=True)
    _rasterize(svg, png, px)
    return Image.open(png).convert("RGBA")


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"missing source art: {SOURCE}")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        flat = render(_load(), SIZE, "flat", tmp)
        desktop = rounded_tile(flat, CORNER_RADIUS)
        desktop.save(ICON_DIR / "icon.png")
        desktop.resize((256, 256), Image.LANCZOS).save(ICON_DIR / "app_icon_256.png")
        rounded_tile(flat, MACOS_RADIUS, MACOS_INSET).save(ICON_DIR / "icon_macos.png")

        bg = render(_background_svg(), SIZE, "background", tmp).convert("RGB")
        bg.save(ICON_DIR / "icon_background.png")

        inner = round(SIZE * FILL_ADAPTIVE)
        logo = render(_foreground_svg(), inner, "foreground", tmp)
        canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        canvas.alpha_composite(logo, ((SIZE - inner) // 2, (SIZE - inner) // 2))
        canvas.save(ICON_DIR / "icon_adaptive_foreground.png")

    print("wrote icon.png, app_icon_256.png, icon_macos.png, "
          "icon_background.png, icon_adaptive_foreground.png")


if __name__ == "__main__":
    sys.exit(main())
