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

- **`lib/main.dart`** — the UI and the `_PlayerPageState` player/session
  controller + the other page widgets (recordings, settings, track lists). Still
  the bulk of the app; keep UI here rather than spreading it across files.
- **`lib/icy_reader.dart`** — `MetadataStatus`, the pure `IcyParser` byte-level
  state machine, and `IcyReader` (its own HTTP connection + reconnect/generation
  lifecycle). The metadata side-channel, deliberately decoupled from playback.
- **`lib/stream_recorder.dart`** — `StreamRecorder` (raw-byte song dump) and its
  filename/extension/unique-path statics.
- **`lib/storage_paths.dart`** — `isDesktop`, `recDirKey`, `recordingsDir()`,
  `savedTracksFile()`, `historyFile()`, `listRecordings()`, `isAudioFile()`.
- **`lib/csv_utils.dart`** — `parseCsv` / `csvField` (RFC-4180).
- **`lib/track_utils.dart`** — `splitArtistTitle`, `fmtDateTime`, `fmtDuration`.
- **`test/`** — unit tests for the non-UI modules above (`IcyParser`, CSV,
  recorder helpers, track utils). Run with `~/flutter/bin/flutter test`.
- `linux/`, `windows/`, `macos/`, `android/` — generated platform folders. The desktop window title is set natively in `linux/runner/my_application.cc` (and the Windows equivalent); on **macOS** the title comes from `window_manager` at runtime (no native title code), and the display name is `CFBundleDisplayName` in `macos/Runner/Info.plist`.
- `pubspec.yaml` — dependencies.
- `doc/` — design & implementation docs.

The non-UI logic was extracted from the once-single `main.dart` so the metadata
parser and recorder are independently testable. Keep new **pure/non-UI** logic in
the matching module (and add a test); keep **widgets/UI** in `main.dart`.

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
- **Metadata is decoupled from playback on purpose.** `just_audio`'s `icyMetadataStream` does NOT work on Windows/Linux, so the app parses ICY itself in `IcyReader` (`lib/icy_reader.dart`). Do not "simplify" by switching to `icyMetadataStream`. See `doc/implementation-notes.md`. Key lifecycle pieces:
  - **Pure parser** `IcyParser` (byte state machine) is separate from `IcyReader` (HTTP + lifecycle) so the parser is unit-tested (`test/icy_reader_test.dart`).
  - **`IcyReader.start` takes its callbacks as parameters** (`onTitle`/`onAudio`/`onStatus`) — `_play` passes closures. **Don't** restore the old mutable global `onTitle`/`onAudio` fields.
  - **Two-layer staleness guard against fast station switches:** the player bumps `_playSession` per `_play`/`_stop` and every ICY closure bails if `session != _playSession`; `IcyReader` *also* bumps an internal `_generation` on `start`/`stop` so a superseded connection (and any pending reconnect timer) is inert. Keep both.
  - **`MetadataStatus`** (idle/connecting/waitingForFirstTitle/unsupported/failed/active) drives the now-playing message via `_metaStatusMessage()` so "no `icy-metaint`" reads "doesn't provide track info", a dead connection reads "unavailable", etc. — instead of one ambiguous "Waiting…". A non-empty `_nowPlaying` always wins, so a brief reconnect doesn't blank a shown title.
  - **Dropped metadata connections auto-reconnect** (bounded: ~5 tries, exponential backoff capped at 30 s; a working title resets the budget). `stop()` cancels the timer. This is the real fix for the screen-off "recording never finalizes" class of bug; don't remove the `onDone`/`onError` handling in `_listen`.
  - **Freshness gates Save/Record.** `_trackInfoFresh` is true only while the feed is `active`; it's cleared on any other status (failed/unsupported/connecting) and on `_play`/`_stop`. **Save** keys off `_trackInfoFresh`, *not* `_nowPlaying.isNotEmpty`, so a stale title left after the feed dies can't be saved. The now-playing line (`_nowPlayingText`) keeps showing the title across a brief reconnect, but once reconnects are exhausted shows `Track info unavailable — last: …`.
  - **Recording on title-less stations (manual mode).** A station with no `icy-metaint` (e.g. FIP) has no titles *and* — historically — fed no audio to the recorder. Now `IcyReader.start(bufferWithoutMetadata: …)` (set from `_recBuffering`) keeps that connection open and forwards the **raw** body to `onAudio` (`_listenRaw`), so the buffer fills. `_canRecord` allows recording when `_trackInfoFresh` **or** `_metaStatus == unsupported`. Such a recording is **manual** (`_manualRecording`): there's no track change to auto-finalize on, so tapping Record again **saves** (`_saveManualRecording` → `onTrackChanged`) instead of cancelling, and it's named `<station> <YYYY-MM-DD HH.MM>`. Toggling buffering while on an unsupported station restarts the reader (`_applyRecordingPrefs`) so the raw stream starts/stops to match.
  - **Lead-in cap (`rec_lead_seconds`, manual only).** Without a song boundary the buffer could prepend many minutes of unrelated audio, so manual recordings keep only the last *N* seconds of pre-tap audio (`_recLeadOptions`: 0/30s/1/2/3/4 min/Max; default 60 s; -1 = whole buffer). The player converts seconds→bytes via `_icy.bitrateKbps` (fallback 128) and passes `leadInBytes:` to `arm`; the recorder records from `_recordStartOffset` (computed from segment `startOffset` + the monotonic `_writtenBytes`) at finalize. **Titled recordings pass `null`** — the buffer was reset at the song's start, so they always capture the whole song regardless of this setting.
  - **`_play` stops the old `_icy` up front** (`await _icy.stop()` before `setUrl`), so even a *failed* retune can't leave the previous reader reconnecting in the background.
- **Never `await player.play()`** for these endless streams — its Future only completes when playback *ends*, so awaiting it hangs `_play()` (was invisible on desktop's media_kit backend, broke Android/ExoPlayer). Use `unawaited(_player.play())`. See `doc/android-build.md`.
- **Stream URLs must be direct**, not `.pls`/`.m3u` playlist links (unwrap them first — e.g. SwissGroove's `listen.php` → `relay1.swissgroove.ch:80`).
- **Persistence:** `shared_preferences` keys are `volume`, `stations`, `win_w`, `win_h`, `accent_color`, `history_logging`, `rec_buffering`, `rec_buffer_mb`, `rec_lead_seconds`, `rec_dir`, `rec_never_stops`, `rec_randomize`. Saved tracks (`savedTracksFile()`) and play history (`historyFile()`) are two CSVs in the app documents dir with the **same** `timestamp,station,artist,title,album,raw` header; read/write with `parseCsv` / `csvField` (RFC-4180, no extra dependency).
- **Song recording is a raw-byte dump — do NOT add an audio codec.** Icecast/Shoutcast streams are *already* compressed (MP3/AAC), so recording just writes those bytes verbatim — lossless, instant, zero extra dependencies. `IcyReader` already reads every audio byte to reach the metadata; it forwards them (batched, metadata stripped) via the `onAudio` callback. `StreamRecorder` (`lib/stream_recorder.dart`) buffers the current track to a temp file (`getTemporaryDirectory()`), capped at `rec_buffer_mb` MB (oldest bytes trimmed) until the user hits **Record** (`arm`), then keeps appending; on the next track change (`onTrackChanged`, driven by the ICY title) or stop/station-switch (`onStreamStopped`) it finalizes the buffer to `<output>/Artist - Title.<ext>` (extension from the stream's `Content-Type`). One song at a time; tapping Record again `cancel`s. The record button is hidden when `rec_buffering` is off (no buffer ⇒ nothing to record). **Never** re-encode to change bitrate (would need an ffmpeg-class dep, against the minimalist goal) — the rate is always the stream's own. Track-change handling dedups on `_lastRecTitle` and skips the *first* title of a session so the initial song's buffer isn't reset. **The buffer is a segmented ring** (`_Segment` files, size ≈ ⅛ of the cap, 1–16 MB): `addAudio` appends to the active segment, rolls a new one when it fills, and — until armed — drops the oldest *whole* segment (an O(1) delete, no read) once the rest still covers the cap. This deliberately replaced a single-file design that rewrote ~cap bytes to trim (a recurrent multi-MB RAM spike + UI hitch). **Don't reintroduce a read-all-and-rewrite trim in `addAudio`.** Finalize concatenates the live segments (streamed in 1 MB chunks; one-segment songs take a rename fast path). `rec_buffer_mb` is capped at `_recBufferMbMax` (128 MB; old larger saved values are clamped on read) to bound disk use + the finalize copy. **The async lifecycle ops (`startBuffering`/`onTrackChanged`/`onStreamStopped`/`dispose`) are serialized through `_runExclusive`** so a metadata-driven finalize can't interleave with `_stop`'s finalize and corrupt the shared segment state; `addAudio` is synchronous and unqueued — it no-ops whenever there's no open active segment (i.e. during teardown). Public ops call private bodies (`_startBuffering`, etc.) to avoid re-entrant deadlock. The ring buffer's segment dir + size are injectable (`bufferDirResolver` / `segmentBytesOverride`) so it's unit-tested (`test/stream_recorder_test.dart`). See `doc/implementation-notes.md`.
- **Background playback + recording survive screen-off on Android via a foreground service** (`flutter_foreground_task`). Both playback and the recording/metadata path (`IcyReader`'s socket loop) run on the main isolate; with the screen off and the app backgrounded, Android's Doze freezes them, so playback dies and the next-track signal that finalizes a recording never arrives. **One** method, `_syncPlaybackService`, keeps it all in step: while a station is active (`_current != null`) it raises/updates a `mediaPlayback` foreground service (wake-lock + Wi-Fi-lock) with a notification — a **Stop** button + now-playing/recording text — and tears it down when `_current` is null. It's called from `_play` (start/refresh), `_stop` (tear down), `_handleTrackChange` (refresh title + cleared recording state), `_toggleRecord` (reflect/clear "Recording"), and the buffering-off branch of `_applyRecordingPrefs`. **Android-only** (`Platform.isAndroid`), best-effort (failures swallowed — playback/recording still work in the foreground). The notification's **Stop** button is delivered through a background **task-handler isolate** (top-level `_foregroundTaskCallback` → `_PlaybackServiceHandler.onNotificationButtonPressed` → `sendDataToMain('stop')`); the UI isolate registers `_onForegroundData` via `addTaskDataCallback` (in `initState`, removed in `dispose`) and calls `_stop`. Tapping the notification body calls `launchApp()`. Configured once in `main()` (`FlutterForegroundTask.initCommunicationPort()` + `init` with `ForegroundTaskEventAction.nothing()` — no periodic event, the handler only relays button taps). Manifest needs `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` + `POST_NOTIFICATIONS` + `WAKE_LOCK` and the `com.pravera.flutter_foreground_task.service.ForegroundService` declaration. **Not** `just_audio_background` — it allows only one `AudioPlayer` app-wide and would crash `_RecordingsPage`'s separate player; a standalone service avoids that and needs no MediaItem/AudioSource migration. (Live radio has no pause concept — Stop is the only control. This doesn't change the *other* ICY-metadata limitation: stations that announce a title early can still make a recording cut feel early.) The UI also glows a red neon border on the now-playing box while `_recording`.
- **Settings** (`_SettingsPage`, app-bar gear icon — on the player **and** the recordings view) is one combined screen: **Appearance** (accent color) on top, then the recording prefs. **Accent color:** the Material 3 seed (`colorSchemeSeed`) lives in a top-level `ValueNotifier<Color> accentColor` (default `_defaultAccentValue` = teal, persisted as `accent_color`); `RadioApp` wraps `MaterialApp` in a `ValueListenableBuilder` on it, so picking a color re-themes the whole app **live**. The settings page offers preset swatches + R/G/B sliders (`Color.fromARGB` / `.toARGB32()` / `.r`·`.g`·`.b` — the non-deprecated color API; don't use `.value`/`.red`). `main()` loads the saved accent before `runApp`; `_TrackListPage`'s forced-dark `Theme` reads `accentColor.value` too. The recording prefs are written directly; the player re-applies them on pop via `_applyRecordingPrefs` (which also starts/stops live buffering on a toggle). The buffer-size slider (5–`_recBufferMbMax` MB) has a `_bufferGuide` caption showing the MB cost of a minute of MP3 at 128/256/320 kbps and how many minutes the chosen size rewinds, so the size choice is meaningful. Output folder defaults to `getDownloadsDirectory()` on desktop (picked via `file_picker`'s `getDirectoryPath`), falling back to the app documents dir; on Android it always uses the app folder (arbitrary-folder writes need SAF, not done).
- **Recordings library** (`_RecordingsPage`, app-bar `library_music` icon, between Saved tracks and Settings) lists/plays the audio files in the recordings folder. It owns its **own** `AudioPlayer` (separate from the radio's `_player`), applies the saved `volume`, and **stops playback on dispose** (leaving the view). Starting a song calls the passed-in `stopRadio` (the player's `_stop`) **once** so the two never sound together. Track names are parsed from filenames via `splitArtistTitle`. `rec_never_stops` auto-advances on `ProcessingState.completed`; `rec_randomize` picks the next file via `Random()` (affects both auto-advance and the skip button). Folder is located by the shared top-level `recordingsDir()` (the recorder's `outputDirResolver` and `listRecordings()` both use it); `isAudioFile` gates the listed extensions. Export writes an `artist,title` CSV via the same `file_picker` `saveFile` flow as `_exportStations`. Per-row overflow menu offers **Delete** (`_deleteFile`, confirm dialog, frees space) and **Share/move** (`_shareFile` via `share_plus`, mobile only); a desktop-only **folder** icon (`_openFolder`) reveals the dir. **Don't** await `_player.play()` for these files either — completion is observed on `playerStateStream` (and auto-advance is deferred off that callback to avoid a re-entrant parked-playback bug); duration comes from `durationStream`, not `setFilePath`. On Android it gets the **same foreground-service treatment** as the radio (background playback with the screen off) via its own `_syncRecordingsService` (driven off the player-state stream), with richer lock-screen controls suited to finite files — **Pause/Play + Skip + Stop**. Button IDs are prefixed `rec_` (`rec_toggle`/`rec_skip`/`rec_stop`) so the radio page's still-registered `_onForegroundData` ignores them; the recordings page registers its own `_onForegroundData` in `initState` and removes it + stops the service in `dispose`. Both pages share the one service singleton — no clash because the radio is stopped (`_current == null`) whenever recordings playback is active.
- **Play history:** the player auto-logs each played song via `_recordHistory` (called from `IcyReader.onTitle`). It dedups against `_lastHistoryTitle` (the ICY reader re-emits the same title every metadata tick) — reset on `_play`/`_stop`. Logging is gated by the `history_logging` pref (default on), toggled from the History view; `_recordHistory` reads the pref directly and bails *before* updating the dedup marker so re-enabling mid-song still logs the current track. Writes are best-effort (errors swallowed), like metadata. **Don't** switch the dedup to `icyMetadataStream` (see metadata note above).
- **Saved-tracks & History share one widget** (`_TrackListPage`, parameterized by `title` / `fileResolver` / `emptyMessage` / `shareSubject` / `isHistory`): sortable `DataTable` on desktop, compact `ListView` + app-bar sort menu on mobile, type-to-search filter (matches artist/title/station), export, and clear. `isHistory` adds the entry-count + logging-toggle band (`_historyControls`). Export/clear act on the **whole** file, never the filtered view. **Paged rendering:** the unbounded history isn't built all at once — only a `_pageSize` (200) window of rows is materialised; it grows on scroll-near-bottom (`_onScroll`/`_showMore`) or the **Show more** footer and resets on filter/sort change (`_resetWindow`). The CSV parse is offloaded to a background isolate via `compute` when the file is >256 KB. Keeps open-time/memory flat regardless of size.
- **Per-station colour.** `Station` has an optional `int? color` (ARGB; null ⇒ default theme colour), persisted in the `stations` JSON (`toJson` omits it when null; `fromJson` tolerates older data without it). `_StationDialog` (used for add *and* edit) has a colour picker — a "Default" chip (`_defaultChoice`) + `_colorPresets` swatches (`_ColorSwatch`, shared with the accent picker) — and returns it via `Station(..., color:)`. `_StationTile` tints both the leading icon and the name `Text` with it. The CSV import/export is still `name,url` only — colour is an app-local visual tag, not exported.
- **Station import/export** (`_importStations` / `_exportStations`) uses `file_picker` for the native open/save dialogs. The CSV is `name,url` with a header row; import merges non-destructively (skips URLs already present) and tolerates a header. On mobile, `file_picker` reads/writes the bytes itself (no path); on desktop we write the chosen path. On Linux it shells out to `zenity`/`kdialog` at runtime.
- **Station filter (type-to-search)** (`_searchBar` / `_openSearch` / `_closeSearch` / `_onPageKey`): a page-level `Focus` catches the first printable keystroke (no Ctrl/Alt/Meta) to open a live name filter; an app-bar search icon is the mobile entry point. `CallbackShortcuts` maps Esc → close. Matches case-insensitive substring on `Station.name`; hides the add/import/export rows while a query is active. Tiles operate by `Station.url`, not list index, so filtering can't desync edit/delete/play. See `doc/implementation-notes.md`.
- **`_defaultStations` mirrors `radios-selection.csv`** (repo root) — keep them in sync when curating the seed set. It only seeds the *first* launch; existing users keep their saved `stations`.
- **`share_plus` is pinned to `^12`** — `^13` needs `win32 ^6`, which conflicts with `file_picker`'s `win32 ^5`. Don't bump it back without re-checking that constraint.
- **`window_manager` is desktop-only** — guard calls with `isDesktop`.
- **App launcher icons** are generated from a single boombox logo by **`flutter_launcher_icons`** (dev dep). Source art lives in `assets/icon/`: `icon.png` (1024² master — boombox cut out of the original spotlight photo via a gradient-aware flood fill, composited on a soft radial-gradient background), `icon_foreground.png` (transparent, boombox sized to stay inside Android's circular adaptive safe zone) + `icon_background.png` (the gradient) for the Android adaptive icon. Config is the `flutter_launcher_icons:` block in `pubspec.yaml`; **regenerate with `~/flutter/bin/dart run flutter_launcher_icons`** after changing the art (it rewrites Android mipmaps/adaptive drawables, `windows/runner/resources/app_icon.ico`, and the macOS `AppIcon.appiconset`). **Linux isn't covered by the tool** — the GTK window/taskbar icon is set natively in `linux/runner/my_application.cc` from the bundled `assets/icon/app_icon_256.png` (declared under `flutter: assets:`, so it ships in `data/flutter_assets/…` next to the executable; the runner reads it via `/proc/self/exe`). Native change ⇒ needs a full `flutter build linux`. No iOS/web icons (those folders don't exist).
- **macOS is an unsigned, CI-built release target** (`macos/` scaffolded via `flutter create --platforms=macos .`). The `.dmg` is built by the `macos` job in `.github/workflows/release.yml` on a `macos-latest` runner — **no Mac hardware, no $99 Apple Developer Program**. Three non-obvious pieces: (1) **the App Sandbox is dropped** — `macos/Runner/Release.entitlements` has no `com.apple.security.app-sandbox`, so the direct-download app gets full network + filesystem access without entitlement tuning (re-add sandbox + `network.client` + file entitlements only if ever targeting the App Store); (2) CI **ad-hoc signs** the `.app` (`codesign --force --deep --sign -`, free, no cert) because Apple Silicon hard-refuses a *truly* unsigned binary as "damaged" — users still right-click → **Open** on first launch to clear Gatekeeper; (3) **no ATS/HTTP exception is needed** — the ICY `dart:io HttpClient` and libmpv playback bypass `NSURLSession`, so plain-HTTP streams work (that's an iOS-only problem). Bundle ID `io.github.flochrislas.eztunein` (in `macos/Runner/Configs/AppInfo.xcconfig`), display name `EZ-TuneIn` (`CFBundleDisplayName` in `Info.plist`). **`flutter build macos` can't run in this Linux env** — verify with `analyze` + `build linux --debug`; the real build is CI/Mac. The full option comparison (incl. codesign+notarize, iOS, TrollStore) is in [`doc/Apple release processes.md`](doc/Apple%20release%20processes.md).
- After any change, run `flutter analyze` (keep it at "No issues found") and rebuild before telling the user it's ready.

## Verification etiquette

This environment can compile but cannot play audio or show the GUI. After a
change: run `dart format lib test` (CI fails on unformatted code — see below),
run `analyze`, run `flutter test`, run `build linux`, then ask the user to run
the binary and report what they see. To inspect live stream behaviour (e.g. ICY
metadata), a small standalone Dart probe run with `~/flutter/bin/dart run` is a
proven approach.

**CI gate:** `.github/workflows/ci.yml` (and the release `verify` job) run
`dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`,
and `flutter test` — keep all three green.

## Not done yet (see implementation-notes for the full list)

- Reorder stations; URL validation; live-refresh of the saved-tracks view.
  (Editing a station, import/export of the list as CSV, and a type-to-search
  station filter **are** done — edit via the hover pencil icon → `_editStation` /
  `_StationDialog`; import/export via `file_picker`; filter via `_searchBar` /
  `_onPageKey`.)
- Android **recording folder** (recordings save to the app folder; picking an
  arbitrary folder like Downloads needs SAF/MediaStore plumbing). Recording
  itself **is** done on all platforms (raw-stream dump via `StreamRecorder`,
  desktop saves to Downloads / a chosen folder).

The Dart package and the on-disk binary are named `ez_tunein`; the application ID
is `io.github.flochrislas.eztunein` (Android + Linux GTK) and the launcher/window
title is `EZ-TuneIn` / `EZ-TuneIn Radio`.
