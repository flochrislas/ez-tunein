# App icon

How the **EZ-TuneIn** launcher icon is built and how to tweak it.

The icon is a boombox on the classic **radio-broadcast motif** — concentric
rings emanating from a centre dot, fading out toward the edges, with a blank
triangular wedge at the bottom. The pattern is drawn programmatically (no raster
source to hand-edit) by [`script/make_icon_bg.py`](../script/make_icon_bg.py)
using Pillow (PIL), so it can be re-rendered crisply and tweaked by changing a
few constants.

## Source art vs. generated art

Everything lives in `assets/icon/`:

| File | Role | Edited by hand? |
|---|---|---|
| `icon_foreground.png` | **Canonical** transparent boombox (1024²) | Yes — this is the *only* source |
| `icon_background.png` | Ring pattern (Android adaptive background) | **Generated** |
| `icon_adaptive_foreground.png` | Boombox enlarged for the Android adaptive foreground | **Generated** |
| `icon.png` | 1024² flat master (boombox composited on the rings) | **Generated** |
| `app_icon_256.png` | 256² flat icon (Linux GTK window/taskbar; also audio_service art) | **Generated** |

`icon_foreground.png` is never overwritten — the script crops it to its bounding
box before scaling, so **re-running the script is idempotent** (it never
compounds an earlier upscale). If you want a different boombox, replace *that*
file (transparent PNG, boombox roughly centred) and re-run.

## Regenerating

Two steps, from the repo root. **Both are needed** — the first produces the art,
the second fans it out to every platform's icon format.

```bash
# 1. Render the pattern + composite the boombox (writes the 4 generated files)
python3 script/make_icon_bg.py          # needs Pillow: pip install pillow

# 2. Regenerate the per-platform launcher icons from the art above
~/flutter/bin/dart run flutter_launcher_icons
```

`flutter_launcher_icons` rewrites the Android mipmaps + adaptive drawables,
`windows/runner/resources/app_icon.ico`, and the macOS `AppIcon.appiconset`
(config is the `flutter_launcher_icons:` block in `pubspec.yaml`, which points
`adaptive_icon_foreground` at the generated `icon_adaptive_foreground.png` and
`adaptive_icon_background` at `icon_background.png`).

**Linux is not covered** by `flutter_launcher_icons`: the GTK window/taskbar icon
is loaded natively in `linux/runner/my_application.cc` from the bundled
`assets/icon/app_icon_256.png`, so a Linux icon change needs a full
`~/flutter/bin/flutter build linux` to re-bundle it.

## Tweaking the look

All knobs are module-level constants at the top of `make_icon_bg.py`. Sizes are
**fractions of the canvas** (resolution-independent); the script supersamples by
`SS` (×4) and downscales for anti-aliasing.

### Ring pattern

| Constant | Meaning | Bigger → |
|---|---|---|
| `CENTRE_Y` | Vertical position of the ring centre (0=top, 1=bottom) | Centre lower |
| `DOT_R` | Solid centre-dot radius | Larger dot |
| `FIRST` | First ring radius, as a multiple of `DOT_R` | Bigger gap before ring 1 |
| `SPACING` | **Constant** gap between rings | Fewer, wider-spaced rings |
| `MAX_R` | Draw rings out to this radius (runs off-canvas) | More rings |
| `WEDGE_HALF` | Half-angle (°) of the blank bottom wedge | Wider blank triangle |
| `GRAY_IN`, `GRAY_OUT` | Ring **shade** at centre → edge (0=black, 255=white) | Lighter |
| `FADE_POW` | Fade easing; `<1` fades **faster** toward the edge | (lower = stronger fade) |
| `STROKE_IN`, `STROKE_OUT` | Ring **width** at centre → edge | Thicker |

Notes:
- **Spacing is deliberately constant** — only the *shade* and *stroke width*
  taper with radius, so the rings look like they dissolve outward rather than
  bunching up. Don't reintroduce geometric growth if you want that look.
- The centre dot uses `GRAY_IN` too (not pure black), so the whole centre reads
  as already slightly faded.
- The wedge works by drawing each ring as an **arc** that skips a downward
  sector (PIL angles go clockwise from 3 o'clock; 90° is straight down), leaving
  a blank triangle with its apex at the centre.

### Boombox size

| Constant | Meaning |
|---|---|
| `FILL` | Flat icon (`icon.png`): boombox fraction of the canvas. It's **width-limited** (the boombox is wider than tall), so `1.0` already touches the side edges. |
| `FILL_ADAPTIVE` | Android adaptive foreground size. Larger reads bigger on the launcher but risks the outer edges being clipped by tight (circle) masks. `0.82` sits comfortably inside a full circle **and** squircle; content beyond ~0.61 leaves the 66/108 "safe zone" (only matters for launcher parallax/animation, not static clipping). |

## Previewing before committing

The script only writes PNGs — it can't show the launcher masks. A quick way to
eyeball circle / rounded-square / adaptive results is a throwaway PIL snippet
that masks `assets/icon/icon.png` (and composites `icon_background.png` +
`icon_adaptive_foreground.png` for the adaptive case). Save it outside the repo
(e.g. `~/icon_preview.png`) so it isn't committed.

## Committing

Commit the four generated `assets/icon/*` files **and** the regenerated platform
icons under `android/`, `macos/`, `windows/`. The Linux binary picks up
`app_icon_256.png` at build time, so nothing extra to commit there. See
[`releasing.md`](./releasing.md) for shipping a new version.
