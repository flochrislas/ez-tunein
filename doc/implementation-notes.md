# Implementation Notes

A developer-oriented walkthrough of how **EZ-TuneIn Radio** is built. For the
original technology evaluation and *why* Flutter was chosen, see
[`tech-stack.md`](./tech-stack.md).

## What the app does

A minimalist internet-radio player:

1. Plays Icecast/Shoutcast streams (SomaFM, SwissGroove, …).
2. Shows the live "now playing" track (artist + title).
3. Saves the current track to a CSV file on a button click.
4. Lets you add/remove stations (and import/export the list as a CSV), filter the
   list by name (type-to-search), adjust & persist volume, browse/sort/copy/clear
   saved tracks, keeps an automatic **play history** (with a logging on/off
   toggle), and (on desktop) remembers its window size.

## Stack

- **Flutter / Dart** — single codebase for Windows, Linux, Android.
- **Playback:** `just_audio`. On Android/iOS it uses ExoPlayer/AVPlayer; on
  desktop it routes through `just_audio_media_kit` (+ `media_kit_libs_audio`),
  which wraps **libmpv**.
- **Track metadata:** a hand-written ICY reader (no package — see below).
- **Persistence:** `shared_preferences` (volume, station list, window size,
  history-logging flag) and two plain CSV files (saved tracks + play history).
- **Window sizing:** `window_manager` (desktop only).
- **Export:** `share_plus` (OS share sheet for the saved-tracks CSV on mobile).
  Pinned to `^12`: `^13` requires `win32 ^6`, which conflicts with
  `file_picker`'s `win32 ^5`.
- **Station list import/export:** `file_picker` (native open/save dialogs on all
  three platforms; on Linux it shells out to `zenity`/`kdialog`).

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
| `_defaultStations` | The seed list used on first launch only (mirrors `radios-selection.csv` at the repo root). |
| `PlayerPage` / `_PlayerPageState` | The main screen. Owns the `AudioPlayer`, the `IcyReader`, the station list, volume, and (via `WindowListener`) window-resize persistence. `_recordHistory` logs each played song (see [Play history](#play-history)). |
| `_StationTile` | A station row that reveals its edit + delete buttons only on hover (`MouseRegion`). |
| `_actionTile` | The dimmed/italic list rows for add / import / export at the end of the station list. |
| `_searchBar` / `_openSearch` / `_closeSearch` / `_onPageKey` | The type-to-search station filter (see [Filtering](#filtering--type-to-search)). |
| `_importStations` / `_exportStations` | Import/export the station list as a `name,url` CSV via `file_picker`. |
| `_StationDialog` | Minimal name + URL dialog; returns a `Station`. Pre-fills from `initial` to edit (vs. add). |
| `_TrackListPage` / `SavedTrack` | The shared sortable/searchable table screen, used for **both** saved tracks and play history (parameterized by `title` / `fileResolver` / `emptyMessage` / `shareSubject` / `isHistory`). `_export` shares the CSV (share sheet on mobile, reveal-in-folder on desktop); `_historyControls` adds the count + logging toggle when `isHistory`. |
| `IcyReader` | The ICY metadata reader described above. |
| `savedTracksFile()` / `historyFile()` | Resolve the two CSV paths (`radio_saved_tracks.csv` / `radio_history.csv`). |
| `_splitArtistTitle` | Splits a raw ICY `"Artist - Title"` string; shared by save + history. |
| `_parseCsv` / `_csvField` | RFC-4180 CSV read/write (no dependency). |
| `_fmtDateTime` | Formats the ISO timestamp as `YYYY-MM-DD HH:MM`. |

## Data & persistence

- **`shared_preferences` keys:**
  - `volume` (double, 0.0–1.0)
  - `stations` (JSON string — array of `{name, url}`)
  - `win_w`, `win_h` (doubles)
  - `history_logging` (bool, default `true` — whether the player logs to history)
- **Saved tracks CSV:** `getApplicationDocumentsDirectory()/radio_saved_tracks.csv`
  with header `timestamp,station,artist,title,album,raw`.
  - **Play history** uses a second CSV, `radio_history.csv`, in the same
    directory with the **same** header (so the same parser, table, export, and
    clear logic serve both — see [Play history](#play-history)).
  - On Linux/Windows this is the user's real **Documents** folder.
  - On Android it's an app-private directory (not browsable from a file manager).
    The saved-tracks view's **Share** action (`_export`) gets the file off the
    device — see [Export / share](#export--share-the-csv) below.
  - `album` is effectively always empty: ICY streams don't carry it. `raw` keeps
    the full original `StreamTitle` as a fallback.

### Notable flows

- **Now playing:** `_play()` calls `player.setUrl`, then `player.play()`
  **un-awaited**, then `IcyReader.start(url)`. The reader pushes titles via
  `onTitle`, which `setState`s `_nowPlaying`. Titles auto-update on each metadata
  tick (so a momentary partial title from the server self-corrects on the next
  block).
  - **Why `play()` is not awaited:** `just_audio`'s `play()` Future completes
    only when playback *ends*, which never happens for an endless stream —
    awaiting it would block `_play()` forever, leaving the UI stuck on
    "Connecting…" and `IcyReader.start` unreached. The desktop media_kit backend
    happened to return promptly, so this only surfaced on Android (ExoPlayer).
    See [`android-build.md`](./android-build.md).
- **Save track:** splits `_nowPlaying` on the first `" - "` into artist/title,
  CSV-escapes each field, appends a row (writing the header first if the file is
  new).
- **Add/edit/remove stations:** mutate `_stations`, then `_saveStations()` writes
  the JSON. Adding rejects a URL already present (exact-string match). Editing
  (`_editStation`) reuses `_StationDialog` pre-filled with the station, rejects a
  URL change that collides with a *different* station, replaces the entry in place
  (preserving order), and — if the edited station was playing — points `_current`
  at the new object so the highlight/label stay in sync (the audio keeps running
  on the old connection until the user re-taps). Removing the currently-playing
  station stops playback first.
- **Play history:** see [Play history](#play-history).
- **Filtering (type-to-search):** see [Filtering](#filtering--type-to-search).
- **Volume:** applied to the player *before* first playback on restore, so the
  first stream already uses the saved level.
- **Window size:** restored in `main()`; saved on `onWindowResize`, **debounced
  400 ms** so dragging doesn't hammer the prefs store. Size only — not position.
- **Saved-tracks view:** loads a snapshot on open (reloads each time the screen
  is opened, but does not live-update while open). Sorting on any field sorts
  `_tracks` in place (date on the raw ISO string; artist/title/station
  case-insensitive). Row tap copies `"artist - title"` to the clipboard.
  Clear-all confirms, then truncates the file back to just the header.
  - **Responsive layout** (`_buildDataTable` / `_buildCompactList`): desktop shows
    the full sortable `DataTable`; on mobile that's too wide and forces horizontal
    scrolling, so phones get a `ListView` of compact rows ("Artist — Title" over a
    muted "station · date"). The compact list has no column headers, so sorting
    moves to a `PopupMenuButton` in the app bar (value is a `(columnIndex,
    ascending)` record passed straight to `_onSort`).

### Export / share the CSV

`_export()` (the shared `_TrackListPage`, so both saved tracks and history) is
**platform-adaptive**:

- **Mobile (Android/iOS):** hands the CSV to the OS share sheet via `share_plus`
  (`SharePlus.instance.share` with an `XFile`) — email, Quick Share, Drive, "Save
  to Files", etc.
- **Desktop (Linux/Windows/macOS):** the file is already in the user's Documents
  folder, so instead it copies the path to the clipboard and offers an **Open
  folder** action (`xdg-open` / `explorer` / `open`). `share_plus` doesn't support
  file sharing on Linux, so this branch sidesteps that too.

The action is disabled when the list is empty.

### Import / export the station list

Two dimmed action rows sit at the end of the station list (after "Add a new
radio station…"), built by `_actionTile`. Both use **`file_picker`** for the
native dialogs:

- **Export** (`_exportStations`): builds a `name,url` CSV (header row +
  `_csvField`-escaped rows) and opens a save dialog. On desktop `saveFile`
  returns the chosen path and we `writeAsString`; on mobile there's no writable
  path, so we hand `file_picker` the `bytes` and it writes the file itself.
- **Import** (`_importStations`): opens a file picker (`withData: true` so mobile
  gets the bytes), reads the file (`bytes` on mobile, `path` on desktop), parses
  it with the shared `_parseCsv`, and **merges non-destructively** — it skips any
  URL already present (same dedup rule as add) and tolerates an optional
  `name,url` header. A snackbar reports how many were imported vs. skipped.

The CSV format is deliberately just `name,url` (distinct from the richer
saved-tracks CSV) so it's trivial to hand-edit or share. On Linux `file_picker`
requires `zenity`/`kdialog` at runtime.

### Play history

Every song that plays is logged automatically to `radio_history.csv`, viewable
from the **clock** icon in the app bar.

- **Recording (`_recordHistory`).** Called from `IcyReader.onTitle` (same hook
  that updates "now playing"). The reader re-emits the same `StreamTitle` on every
  metadata tick, so it dedups against `_lastHistoryTitle` and appends a row only
  when the title changes; `_lastHistoryTitle` resets in `_play`/`_stop` so a new
  session (or the same song on another station) logs afresh. A song is captured
  the moment its info arrives — even a brief listen counts. Rows reuse
  `_splitArtistTitle` + `_csvField` and the saved-tracks header; writes are
  best-effort (errors swallowed), like metadata. The history is **unbounded** —
  it grows one row per song until cleared.
- **Logging toggle.** A `history_logging` bool (default on) gates recording. It's
  toggled from the History view's control band (`_historyControls`, shown only
  when `isHistory`), which also displays the entry count. `_recordHistory` reads
  the pref **directly** and bails *before* updating `_lastHistoryTitle`, so
  flipping logging back on mid-song still captures the current track. The History
  page and the player both reach the flag through `shared_preferences`' single
  cached instance, so the toggle takes effect immediately with no extra plumbing.
- **Shared view (`_TrackListPage`).** History and saved tracks are the *same*
  widget, differing only by `title` / `fileResolver` / `emptyMessage` /
  `shareSubject` / `isHistory`. Sort, the desktop/compact layouts, type-to-search
  (matching artist/title/station), export, and clear are therefore identical.
  Export and clear always act on the whole file, not the filtered view; the entry
  count is a snapshot taken when the view opens (no live refresh, like the rest of
  this screen).

### Filtering / type-to-search

With a sizeable default list, the station list has a live name filter:

- **Opening it.** On desktop the page body is wrapped in a `Focus` (`_pageFocus`,
  `autofocus: true`) whose `onKeyEvent` (`_onPageKey`) catches the first
  keystroke: a single printable character with **no** Ctrl/Alt/Meta held opens the
  search bar seeded with that char (so the keypress isn't lost). Non-printable
  keys (Enter, Tab, arrows, F-keys) and modifier combos are ignored, so shortcuts
  still work. On mobile there's no hardware keyboard, so a **search** icon in the
  app bar (`_openSearch`) is the entry point — it works on desktop too.
- **The bar** (`_searchBar`) is a dense `TextField` shown above the list only
  while `_searching`; it owns `_searchFocus` and updates `_query` on change.
- **Matching** is case-insensitive substring on `Station.name`. While a query is
  active the add/import/export action rows are hidden (so results are just
  stations), and an empty result shows a muted "No stations match…" line.
- **Dismissing.** A page-level `CallbackShortcuts` maps **Esc** → `_closeSearch`
  (it resolves up the focus chain, so it fires even while the field is focused);
  the bar's **✕** does the same. `_closeSearch` clears the query and returns focus
  to `_pageFocus` so the next keystroke can re-open it.
- Edit/delete/play key off `Station.url`, not list index, so operating on a
  filtered view never touches the wrong station.

## Platform notes

- **Desktop window title** (`linux/runner/my_application.cc`, and the Windows
  equivalent) is native C++ and set to `EZ-TuneIn Radio`. Changing it requires a
  full rebuild, not hot-reload.
- **Linux** needs `libmpv-dev` / `mpv` installed (the media_kit backend links
  against libmpv). See [`../README.md`](../README.md).
- **Windows** bundles its media_kit libs — no system install needed.
- **Android (builds & runs):** verified on a physical device (audio, live
  metadata, save/view tracks). The manifest declares the `INTERNET` permission
  and `android:usesCleartextTraffic="true"` (the HTTP SwissGroove relay needs the
  latter). Setup, the `play()` gotcha, and release-signing TODOs live in
  [`android-build.md`](./android-build.md).

## Known limitations / possible next steps

- Stations can be added/removed/edited but not **reordered**.
- No URL validation beyond non-empty; a bad URL surfaces as a "Could not play"
  snackbar.
- The saved-tracks and history views are snapshots (no live refresh while open);
  the history entry count likewise reflects open-time.
- Play history is **unbounded** — it grows until the user clears it (there's a
  logging on/off toggle, but no automatic size cap or retention window).
- The application ID is `io.github.flochrislas.eztunein` (Android `applicationId`
  + `namespace`, and the Linux GTK `APPLICATION_ID` — which determines the
  `shared_preferences` directory). The Dart **package** and the on-disk **binary**
  are named `ez_tunein` (`name:` in `pubspec.yaml`; `BINARY_NAME` in the Linux /
  Windows CMake). The launcher/window title is `EZ-TuneIn` (Android `android:label`)
  / `EZ-TuneIn Radio` (desktop window title).
- `album` column is always blank for ICY sources; a per-station JSON API (e.g.
  SomaFM's) could fill it in.
