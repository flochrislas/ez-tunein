# App icon

How the **EZ-TuneIn** launcher icon is built and how to tweak it.

The icon is a red disc with a white music note, flanked by two red
"broadcast" arcs, on a near-black square (a dark-red radial glow behind the
disc). It's a **vector** drawing — `assets/icon/icon.svg`, authored in Inkscape
— and every PNG the build needs is rasterized from it by
[`script/make_icons.py`](../script/make_icons.py).

## Source art vs. generated art

Everything lives in `assets/icon/`:

| File | Role | Edited by hand? |
|---|---|---|
| `icon.svg` | **Canonical** vector logo (180² viewBox) | Yes — this is the *only* source |
| `icon.png` | 1024² rounded tile (Windows, Android legacy) | **Generated** |
| `app_icon_256.png` | 256² rounded tile (Linux GTK window/taskbar; also audio_service art) | **Generated** |
| `icon_macos.png` | 1024² Apple-template tile — rounder **and** inset | **Generated** |
| `icon_background.png` | Android adaptive background — the bare gradient, full-bleed square | **Generated** |
| `icon_adaptive_foreground.png` | Android adaptive foreground — the logo alone, on transparency | **Generated** |

Redesigning the icon means replacing `icon.svg` and re-running the two commands
below. Nothing else is hand-maintained.

## Regenerating

Two steps, from the repo root. **Both are needed** — the first rasterizes the
art, the second fans it out to every platform's icon format.

```bash
# 1. SVG → the four PNGs above
python3 script/make_icons.py     # needs Pillow + a rasterizer (see below)

# 2. Regenerate the per-platform launcher icons from those PNGs
~/flutter/bin/dart run flutter_launcher_icons
```

The script rasterizes with the first of **`rsvg-convert`** (`apt install
librsvg2-bin`), **Inkscape**, or **headless Chrome** that it finds on `PATH`.
Chrome is the fallback that happens to be present on the dev machine — it's
driven through a tiny generated HTML wrapper because Chrome renders a bare
`<img>` SVG at its natural size, not the window size.

`flutter_launcher_icons` rewrites the Android mipmaps + adaptive drawables,
`windows/runner/resources/app_icon.ico`, and the macOS `AppIcon.appiconset`
(config is the `flutter_launcher_icons:` block in `pubspec.yaml`, which points
`adaptive_icon_foreground` at the generated `icon_adaptive_foreground.png` and
`adaptive_icon_background` at `icon_background.png`).

**Linux is not covered** by `flutter_launcher_icons`: the GTK window/taskbar icon
is loaded natively in `linux/runner/my_application.cc` from the bundled
`assets/icon/app_icon_256.png`, so a Linux icon change needs a full
`~/flutter/bin/flutter build linux` to re-bundle it.

## How the adaptive halves are derived

Android's adaptive icon wants the artwork split in two, but keeping a second
hand-drawn copy of the logo in sync is exactly the kind of drift this project
avoids. Instead `make_icons.py` derives both halves from `icon.svg` **in memory**
(nothing extra is written to `assets/icon/`), by id:

| Id in `icon.svg` | What it is | What the script does |
|---|---|---|
| `layer5` | Full-bleed gradient rect | The **background**: everything else is dropped. For the **foreground**: dropped. |
| `path8-4` | The stroked circle the arcs are cut from | Clipped to the band between the bars (see below) |
| `rect27`, `rect27-0` | Opaque black bars that hide the ring's top and bottom | Deleted from the foreground |

The bars are a drawing trick: the "arcs" are really one full circle with its top
and bottom painted over in the background colour. That only works over an opaque
background — on the transparent adaptive foreground they'd show as black bars.
So the foreground replaces them with a `clipPath` limited to the vertical band
between them, which is geometrically identical (the bars are wider than the
circle everywhere they touch it) but leaves transparency behind.

**This derivation is id-based.** If the drawing is restructured in Inkscape and
those ids change, the script fails loudly with the offending id rather than
silently emitting a black square — update the constants at the top of
`make_icons.py` to match.

## Corner shape — who owns it

A hard square reads as dated on every platform where the **app** owns the icon's
shape, which is all of them except Android:

| Platform | Who shapes the icon | What we ship |
|---|---|---|
| Android | **The launcher** masks the adaptive layers (circle/squircle/teardrop, device-dependent) | Full-bleed squares — `icon_background.png` + `icon_adaptive_foreground.png`. **Never round these**; the mask would clip an already-rounded tile. |
| GNOME / Linux | The app | `app_icon_256.png` — `CORNER_RADIUS` (12%), roughly Adwaita's own app tiles |
| Windows | The app (no rounding convention) | `icon.png` — same 12% tile; harmless there and consistent with Linux |
| macOS | The app; the Dock does **no** masking | `icon_macos.png` — Apple's template, see below |

macOS is the strict one. Since Big Sur the convention isn't just "rounded": the
tile is a squircle-ish rounded rect **inset** inside the canvas (~80%), which is
what makes every Dock icon optically the same size. Full-bleed art sits visibly
larger than its neighbours, so macOS gets its own asset — `pubspec.yaml` points
`macos: image_path:` at it while `image_path:`/`windows:` keep the fuller tile.

## Tweaking the look

Everything visual lives in `icon.svg` — edit it in Inkscape. The script's knobs:

| Constant | Meaning |
|---|---|
| `CORNER_RADIUS` | Corner radius of `icon.png` / `app_icon_256.png`, as a fraction of the canvas (0.12). Raise for a more phone-like tile; 0 gives back the old hard square. |
| `MACOS_RADIUS` | Corner radius of `icon_macos.png`, as a fraction of **the tile** (0.225) — so the curve is unaffected by `MACOS_INSET`. |
| `MACOS_INSET` | Tile side as a share of the canvas (0.805), i.e. Apple's transparent margin. |
| `FILL_ADAPTIVE` | Fraction of the adaptive-foreground image the logo is scaled to. Android shows only the central **72/108** (0.667) of an adaptive icon and treats **66/108** (0.611) as the safe zone — but `flutter_launcher_icons` additionally wraps the foreground in an `android:inset="16%"` (visible in the generated `mipmap-anydpi-v26/ic_launcher.xml`), shrinking it to 0.68. At `0.96` the arc tips land at ≈**0.64** of the icon canvas: inside every launcher mask, a hair outside the safe zone (which only governs parallax during launcher animations). |

## Previewing before committing

The script only writes PNGs — it can't show the launcher masks. A throwaway PIL
snippet that composites `drawable-xxxhdpi/ic_launcher_background.png` with
`ic_launcher_foreground.png` scaled by the 16% inset, then masks the result with
a circle and a squircle, shows what Android will actually draw. Save it outside
the repo (e.g. `~/icon_preview.png`) so it isn't committed.

## Committing

Commit `assets/icon/icon.svg`, the five generated `assets/icon/*.png`, **and**
the regenerated platform icons under `android/`, `macos/`, `windows/`. The Linux
binary picks up `app_icon_256.png` at build time, so nothing extra to commit
there. See [`releasing.md`](./releasing.md) for shipping a new version.

## Not covered

The monochrome status-bar / media-notification glyph
(`android/app/src/main/res/drawable/ic_stat_media.xml`) is a separate,
hand-written 24dp vector — Android renders it as a flat white silhouette, so the
colour logo can't be reused there. It isn't regenerated by any of the above.
