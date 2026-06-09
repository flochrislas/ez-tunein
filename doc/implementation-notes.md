# Implementation Notes

A developer-oriented walkthrough of how **EZ-TuneIn Radio** is built. For the
original technology evaluation and *why* Flutter was chosen, see
[`tech-stack.md`](./tech-stack.md).

## What the app does

A minimalist internet-radio player:

1. Plays Icecast/Shoutcast streams (SomaFM, SwissGroove, …).
2. Shows the live "now playing" track (artist + title).
3. Saves the current track to a CSV file on a button click.
4. Lets you add/remove stations, adjust & persist volume, browse/sort/copy/clear
   saved tracks, and (on desktop) remembers its window size.

## Stack

- **Flutter / Dart** — single codebase for Windows, Linux, Android.
- **Playback:** `just_audio`. On Android/iOS it uses ExoPlayer/AVPlayer; on
  desktop it routes through `just_audio_media_kit` (+ `media_kit_libs_audio`),
  which wraps **libmpv**.
- **Track metadata:** a hand-written ICY reader (no package — see below).
- **Persistence:** `shared_preferences` (volume, station list, window size) and a
  plain CSV file (saved tracks).
- **Window sizing:** `window_manager` (desktop only).

Everything lives in a single file, **`lib/main.dart`** — the app is small enough
that splitting it would add more ceremony than clarity.

## The key design decision: metadata is decoupled from playback

This is the most important thing to understand.

`just_audio` exposes an `icyMetadataStream`, but **it is only populated on
Android/iOS/macOS**. On Windows and Linux the libmpv (media_kit) backend does
**not** feed `StreamTitle` into that stream. Since Windows is the primary target,
relying on it would mean the core "save the song" feature silently returns
nothing on the two main platforms.

So metadata is handled independently of the audio backend by **`IcyReader`**
(bottom of `main.dart`):

- It opens its **own** HTTP connection to the stream with the header
  `Icy-MetaData: 1`.
- The server then interleaves metadata blocks into the audio every
  `icy-metaint` bytes (a value it returns in a response header).
- A byte-level state machine walks the stream: skip `icy-metaint` audio bytes →
  read 1 length byte (× 16 = block size) → read that many metadata bytes →
  repeat. State persists across chunk boundaries, so split TCP packets are fine.
- Each metadata block is decoded and `StreamTitle='...'` is extracted. The regex
  anchors on the trailing `StreamUrl=` field (which SomaFM always sends) so a
  title containing `';` isn't cut short; it falls back to a plain match.

**Consequence — and the trade-off:** this downloads the stream a *second* time
(audio bytes are read and discarded just to reach the metadata). At ~128 kbps
that's negligible, and the payoff is identical behaviour on all three platforms.

`IcyReader.onTitle` is a simple callback the UI sets; playback continues
regardless of whether metadata succeeds (it's best-effort and swallows errors).

> Note: stream "listen" links are often `.pls`/`.m3u` playlists, not the audio
> itself. `just_audio` and `IcyReader` both need the **direct** stream URL. For
> example, SwissGroove's `listen.php` is an M3U pointing at
> `http://relay1.swissgroove.ch:80`, which is what the app actually uses.

## Code map (`lib/main.dart`)

| Symbol | Role |
|---|---|
| `main()` | Inits the desktop audio backend; on desktop restores saved window size via `window_manager` before showing the window. |
| `RadioApp` | `MaterialApp` — dark Material 3 theme (teal seed), debug banner off. |
| `Station` | `{name, url}` value object with `toJson`/`fromJson`. |
| `_defaultStations` | The seed list used on first launch only. |
| `PlayerPage` / `_PlayerPageState` | The main screen. Owns the `AudioPlayer`, the `IcyReader`, the station list, volume, and (via `WindowListener`) window-resize persistence. |
| `_StationTile` | A station row that reveals its delete button only on hover (`MouseRegion`). |
| `_AddStationDialog` | Minimal name + URL dialog; returns a `Station`. |
| `SavedTracksPage` / `SavedTrack` | The saved-tracks table screen. |
| `IcyReader` | The ICY metadata reader described above. |
| `savedTracksFile()` | Resolves the CSV path (shared by writer and reader). |
| `_parseCsv` / `_csvField` | RFC-4180 CSV read/write (no dependency). |
| `_fmtDateTime` | Formats the ISO timestamp as `YYYY-MM-DD HH:MM`. |

## Data & persistence

- **`shared_preferences` keys:**
  - `volume` (double, 0.0–1.0)
  - `stations` (JSON string — array of `{name, url}`)
  - `win_w`, `win_h` (doubles)
- **Saved tracks CSV:** `getApplicationDocumentsDirectory()/radio_saved_tracks.csv`
  with header `timestamp,station,artist,title,album,raw`.
  - On Linux/Windows this is the user's real **Documents** folder.
  - On Android it's an app-private directory (not browsable) — to revisit when
    Android is targeted.
  - `album` is effectively always empty: ICY streams don't carry it. `raw` keeps
    the full original `StreamTitle` as a fallback.

### Notable flows

- **Now playing:** `_play()` calls `player.setUrl` + `player.play`, then
  `IcyReader.start(url)`. The reader pushes titles via `onTitle`, which
  `setState`s `_nowPlaying`. Titles auto-update on each metadata tick (so a
  momentary partial title from the server self-corrects on the next block).
- **Save track:** splits `_nowPlaying` on the first `" - "` into artist/title,
  CSV-escapes each field, appends a row (writing the header first if the file is
  new).
- **Add/remove stations:** mutate `_stations`, then `_saveStations()` writes the
  JSON. Adding rejects a URL already present (exact-string match). Removing the
  currently-playing station stops playback first.
- **Volume:** applied to the player *before* first playback on restore, so the
  first stream already uses the saved level.
- **Window size:** restored in `main()`; saved on `onWindowResize`, **debounced
  400 ms** so dragging doesn't hammer the prefs store. Size only — not position.
- **Saved-tracks table:** loads a snapshot on open (reloads each time the screen
  is opened, but does not live-update while open). Sortable by any column
  (date sorts on the raw ISO string; artist/title case-insensitive). Row tap
  copies `"artist - title"` to the clipboard. Clear-all confirms, then truncates
  the file back to just the header.

## Platform notes

- **Desktop window title** (`linux/runner/my_application.cc`, and the Windows
  equivalent) is native C++ and set to `EZ-TuneIn Radio`. Changing it requires a
  full rebuild, not hot-reload.
- **Linux** needs `libmpv-dev` / `mpv` installed (the media_kit backend links
  against libmpv). See [`../README.md`](../README.md).
- **Windows** bundles its media_kit libs — no system install needed.
- **Android (not yet built):** would need the Android SDK; the HTTP SwissGroove
  relay needs `android:usesCleartextTraffic="true"`; and the saved-tracks CSV
  location should be reconsidered (app-private dir → add export/share).

## Known limitations / possible next steps

- Stations can be added/removed but not **edited** or **reordered**.
- No URL validation beyond non-empty; a bad URL surfaces as a "Could not play"
  snackbar.
- Saved-tracks view is a snapshot (no live refresh while open).
- The internal Flutter package name is still `radio` (binary name, Android app
  id `com.example.radio`) — rename deliberately before shipping.
- `album` column is always blank for ICY sources; a per-station JSON API (e.g.
  SomaFM's) could fill it in.
