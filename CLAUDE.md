# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**EZ-TuneIn Radio** — a minimalist, lightweight Flutter internet-radio player.
It plays Icecast/Shoutcast streams (SomaFM, SwissGroove, …), shows the live
"now playing" track, and saves tracks to a CSV on a button click.

- **Primary target:** Windows 11. **Also:** Linux (current dev machine). **Later:** Android.
- **Priorities:** minimalist UI, light footprint, simple code.
- Most development and verification so far has been on **Ubuntu (Linux desktop)**.

## Read these first

- `doc/implementation-notes.md` — how the app is built (architecture, code map, key decisions). **Start here.**
- `doc/tech-stack.md` — why Flutter/just_audio was chosen + the metadata caveat.
- `README.md` — setup/run/install steps.

## Version control

This is a git repo, public on GitHub at **https://github.com/flochrislas/ez-tunein**
(`origin`, default branch `main`). Licensed **GPL-3.0** (`LICENSE`).

- Commits use a **repo-local** identity (`git config --local`) with a GitHub
  noreply email — do not change it to the global/work identity, and don't expose
  a real email in commit history.
- `git log` is now part of the project's history — use it for context on past changes.
- **Releases** are built & published by GitHub Actions on a `v*` tag push (signed
  Android APK + Linux tarball + Windows zip → a draft GitHub Release). See
  `doc/releasing.md` for the full process.
- Commit/push only when asked (per the usual workflow rules).

## Layout

- **`lib/main.dart`** — the entire app lives here (intentionally single-file; keep it that way unless it grows substantially).
- `linux/`, `windows/`, `android/` — generated platform folders. The desktop window title is set natively in `linux/runner/my_application.cc` (and the Windows equivalent).
- `pubspec.yaml` — dependencies.
- `doc/` — design & implementation docs.

## Toolchain

Flutter is installed at **`~/flutter`** and may NOT be on `PATH` in a fresh
non-interactive shell. Use the absolute path to be safe:

```bash
~/flutter/bin/flutter <cmd>
~/flutter/bin/dart <cmd>
```

`flutter doctor` is green for Linux desktop **and Android**. The Android SDK is
installed at `~/Android/Sdk` (command-line tools, no Android Studio). The system
default `java` is 8 — too old for Gradle 9 / AGP 9 — so Flutter is configured
(`flutter config --jdk-dir`) to use **JDK 25** at `/usr/lib/jvm/jdk-25`. Setup is
scripted in [`script/android-sdk-install.sh`](script/android-sdk-install.sh) and
[`script/android-udev-fix.sh`](script/android-udev-fix.sh); full details in
[`doc/android-build.md`](doc/android-build.md).

## Common commands

```bash
# After changing dependencies
~/flutter/bin/flutter pub get

# Lint (must be clean before considering work done)
~/flutter/bin/flutter analyze

# Build the Linux desktop app (verifies native toolchain + libmpv linkage)
~/flutter/bin/flutter build linux --debug

# Run the built binary
./build/linux/x64/debug/bundle/ez_tunein

# Android: run on an attached phone / build a release APK
~/flutter/bin/flutter run                 # debug, on the connected device
~/flutter/bin/flutter build apk --release
# Logs without the MediaCodec noise:
~/Android/Sdk/platform-tools/adb logcat -s flutter:*
```

These need network (pub.dev) and/or write to the project, so they run **outside
the command sandbox** — invoke with the sandbox disabled.

### Hot reload vs. rebuild — important

- **Dart-only changes:** if `flutter run -d linux` is attached, hot-reload with
  `r` (or `R` for restart). No manual build needed.
- **Native changes** (anything in `linux/`/`windows/`, or adding/updating a
  plugin dependency): require a **full `flutter build`** — hot-reload won't pick
  them up. The GTK window title and `window_manager`/`media_kit` changes fall in
  this bucket.

There is usually no `flutter run` GUI session available in this environment, so
prefer `flutter build linux --debug` to verify compilation, and let the user run
the binary to confirm runtime behaviour (audio/UI can't be observed here).

## Conventions & gotchas

- **Match the existing style** in `main.dart`: Material 3, dark theme, `FilledButton`s, terse comments that explain *why*.
- **Metadata is decoupled from playback on purpose.** `just_audio`'s `icyMetadataStream` does NOT work on Windows/Linux, so the app parses ICY itself in `IcyReader`. Do not "simplify" by switching to `icyMetadataStream`. See `doc/implementation-notes.md`.
- **Never `await player.play()`** for these endless streams — its Future only completes when playback *ends*, so awaiting it hangs `_play()` (was invisible on desktop's media_kit backend, broke Android/ExoPlayer). Use `unawaited(_player.play())`. See `doc/android-build.md`.
- **Stream URLs must be direct**, not `.pls`/`.m3u` playlist links (unwrap them first — e.g. SwissGroove's `listen.php` → `relay1.swissgroove.ch:80`).
- **Persistence:** `shared_preferences` keys are `volume`, `stations`, `win_w`, `win_h`. Saved tracks are a CSV in the app documents dir (`savedTracksFile()`); read/write with `_parseCsv` / `_csvField` (RFC-4180, no extra dependency).
- **`window_manager` is desktop-only** — guard calls with `_isDesktop`.
- After any change, run `flutter analyze` (keep it at "No issues found") and rebuild before telling the user it's ready.

## Verification etiquette

This environment can compile but cannot play audio or show the GUI. After a
change: run `analyze`, run `build linux`, then ask the user to run the binary
and report what they see. To inspect live stream behaviour (e.g. ICY metadata),
a small standalone Dart probe run with `~/flutter/bin/dart run` is a proven
approach.

## Not done yet (see implementation-notes for the full list)

- Android **release signing** (still uses debug keys). (The Android build itself
  works, and the saved-tracks CSV can be shared off-device via `share_plus` — see
  `doc/android-build.md`.)
- Edit/reorder stations; URL validation; live-refresh of the saved-tracks view.

The Dart package and the on-disk binary are named `ez_tunein`; the application ID
is `io.github.flochrislas.eztunein` (Android + Linux GTK) and the launcher/window
title is `EZ-TuneIn` / `EZ-TuneIn Radio`.
