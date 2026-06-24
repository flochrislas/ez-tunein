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
- **Persistence:** `shared_preferences` keys are `volume`, `stations`, `win_w`, `win_h`, `history_logging`, `rec_buffering`, `rec_buffer_mb`, `rec_dir`, `rec_never_stops`, `rec_randomize`. Saved tracks (`savedTracksFile()`) and play history (`historyFile()`) are two CSVs in the app documents dir with the **same** `timestamp,station,artist,title,album,raw` header; read/write with `_parseCsv` / `_csvField` (RFC-4180, no extra dependency).
- **Song recording is a raw-byte dump — do NOT add an audio codec.** Icecast/Shoutcast streams are *already* compressed (MP3/AAC), so recording just writes those bytes verbatim — lossless, instant, zero extra dependencies. `IcyReader` already reads every audio byte to reach the metadata; it now forwards them (batched, metadata stripped) via `onAudio`. `_StreamRecorder` buffers the current track to a temp file (`getTemporaryDirectory()`), capped at `rec_buffer_mb` MB (oldest bytes trimmed) until the user hits **Record** (`arm`), then keeps appending; on the next track change (`onTrackChanged`, driven by `IcyReader.onTitle`) or stop/station-switch (`onStreamStopped`) it finalizes the buffer to `<output>/Artist - Title.<ext>` (extension from the stream's `Content-Type`). One song at a time; tapping Record again `cancel`s. The record button is hidden when `rec_buffering` is off (no buffer ⇒ nothing to record). **Never** re-encode to change bitrate (would need an ffmpeg-class dep, against the minimalist goal) — the rate is always the stream's own. Track-change handling dedups on `_lastRecTitle` and skips the *first* title of a session so the initial song's buffer isn't reset. See `doc/implementation-notes.md`.
- **Recording settings** (`_RecordingSettingsPage`, app-bar gear icon) writes the three `rec_*` prefs directly; the player re-applies them on pop via `_applyRecordingPrefs` (which also starts/stops live buffering on a toggle). Output folder defaults to `getDownloadsDirectory()` on desktop (picked via `file_picker`'s `getDirectoryPath`), falling back to the app documents dir; on Android it always uses the app folder (arbitrary-folder writes need SAF, not done).
- **Recordings library** (`_RecordingsPage`, app-bar `library_music` icon, between Saved tracks and Settings) lists/plays the audio files in the recordings folder. It owns its **own** `AudioPlayer` (separate from the radio's `_player`), applies the saved `volume`, and **stops playback on dispose** (leaving the view). Starting a song calls the passed-in `stopRadio` (the player's `_stop`) **once** so the two never sound together. Track names are parsed from filenames via `_splitArtistTitle`. `rec_never_stops` auto-advances on `ProcessingState.completed`; `rec_randomize` picks the next file via `Random()` (affects both auto-advance and the skip button). Folder is located by the shared top-level `recordingsDir()` (the recorder's `outputDirResolver` and `listRecordings()` both use it); `_isAudioFile` gates the listed extensions. Export writes an `artist,title` CSV via the same `file_picker` `saveFile` flow as `_exportStations`. Per-row overflow menu offers **Delete** (`_deleteFile`, confirm dialog, frees space) and **Share/move** (`_shareFile` via `share_plus`, mobile only); a desktop-only **folder** icon (`_openFolder`) reveals the dir. **Don't** await `_player.play()` for these files either — completion is observed on `playerStateStream` (and auto-advance is deferred off that callback to avoid a re-entrant parked-playback bug); duration comes from `durationStream`, not `setFilePath`.
- **Play history:** the player auto-logs each played song via `_recordHistory` (called from `IcyReader.onTitle`). It dedups against `_lastHistoryTitle` (the ICY reader re-emits the same title every metadata tick) — reset on `_play`/`_stop`. Logging is gated by the `history_logging` pref (default on), toggled from the History view; `_recordHistory` reads the pref directly and bails *before* updating the dedup marker so re-enabling mid-song still logs the current track. Writes are best-effort (errors swallowed), like metadata. **Don't** switch the dedup to `icyMetadataStream` (see metadata note above).
- **Saved-tracks & History share one widget** (`_TrackListPage`, parameterized by `title` / `fileResolver` / `emptyMessage` / `shareSubject` / `isHistory`): sortable `DataTable` on desktop, compact `ListView` + app-bar sort menu on mobile, type-to-search filter (matches artist/title/station), export, and clear. `isHistory` adds the entry-count + logging-toggle band (`_historyControls`). Export/clear act on the **whole** file, never the filtered view.
- **Station import/export** (`_importStations` / `_exportStations`) uses `file_picker` for the native open/save dialogs. The CSV is `name,url` with a header row; import merges non-destructively (skips URLs already present) and tolerates a header. On mobile, `file_picker` reads/writes the bytes itself (no path); on desktop we write the chosen path. On Linux it shells out to `zenity`/`kdialog` at runtime.
- **Station filter (type-to-search)** (`_searchBar` / `_openSearch` / `_closeSearch` / `_onPageKey`): a page-level `Focus` catches the first printable keystroke (no Ctrl/Alt/Meta) to open a live name filter; an app-bar search icon is the mobile entry point. `CallbackShortcuts` maps Esc → close. Matches case-insensitive substring on `Station.name`; hides the add/import/export rows while a query is active. Tiles operate by `Station.url`, not list index, so filtering can't desync edit/delete/play. See `doc/implementation-notes.md`.
- **`_defaultStations` mirrors `radios-selection.csv`** (repo root) — keep them in sync when curating the seed set. It only seeds the *first* launch; existing users keep their saved `stations`.
- **`share_plus` is pinned to `^12`** — `^13` needs `win32 ^6`, which conflicts with `file_picker`'s `win32 ^5`. Don't bump it back without re-checking that constraint.
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
- Reorder stations; URL validation; live-refresh of the saved-tracks view.
  (Editing a station, import/export of the list as CSV, and a type-to-search
  station filter **are** done — edit via the hover pencil icon → `_editStation` /
  `_StationDialog`; import/export via `file_picker`; filter via `_searchBar` /
  `_onPageKey`.)
- Android **recording folder** (recordings save to the app folder; picking an
  arbitrary folder like Downloads needs SAF/MediaStore plumbing). Recording
  itself **is** done on all platforms (raw-stream dump via `_StreamRecorder`,
  desktop saves to Downloads / a chosen folder).

The Dart package and the on-disk binary are named `ez_tunein`; the application ID
is `io.github.flochrislas.eztunein` (Android + Linux GTK) and the launcher/window
title is `EZ-TuneIn` / `EZ-TuneIn Radio`.
