# Implementation Notes

A developer-oriented walkthrough of how **EZ-TuneIn Radio** is built. For the
original technology evaluation and *why* Flutter was chosen, see
[`tech-stack.md`](./tech-stack.md).

## What the app does

A minimalist internet-radio player:

1. Plays Icecast/Shoutcast streams (SomaFM, SwissGroove, …).
2. Shows the live "now playing" track (artist + title).
3. Saves the current track to a CSV file on a button click.
4. Lets you add stations by **searching the online Radio Browser directory** (or
   manually), remove them, import/export the list as a CSV, filter the
   list by name (type-to-search), adjust & persist volume, browse/sort/copy/clear
   saved tracks, keeps an automatic **play history** (with a logging on/off
   toggle), and (on desktop) remembers its window size.
5. **Records a whole song to a file** — including the part that played before you
   pressed Record — by buffering the live stream (see [Recording](#recording)).
6. **Plays back the recordings** in a small local jukebox with auto-advance,
   shuffle, skip, and CSV export (see [Recordings library](#recordings-library)).

## Stack

- **Flutter / Dart** — single codebase for Windows, Linux, Android.
- **Playback:** `just_audio`. On Android/iOS it uses ExoPlayer/AVPlayer; on
  desktop it routes through `just_audio_media_kit` (+ `media_kit_libs_audio`),
  which wraps **libmpv**.
- **Track metadata:** a hand-written ICY reader (no package — see below).
- **Recording:** no codec package — the ICY reader already walks every audio
  byte, so recording just dumps those (already-compressed) bytes to a file. The
  only recording-related package is `flutter_foreground_task`, used on Android to
  keep the app un-frozen while recording with the screen off (not for the capture
  itself). See [Recording](#recording).
- **Persistence:** `shared_preferences` (volume, station list, window size,
  accent color, history-logging flag, recording settings) and two plain CSV files
  (saved tracks + play history).
- **Window sizing:** `window_manager` (desktop only).
- **Export:** `share_plus` (OS share sheet for the saved-tracks CSV on mobile).
  Pinned to `^12`: `^13` requires `win32 ^6`, which conflicts with
  `file_picker`'s `win32 ^5`.
- **Station list import/export:** `file_picker` (native open/save dialogs on all
  three platforms; on Linux it shells out to `zenity`/`kdialog`).

The UI lives in **`lib/main.dart`**; the non-UI logic (ICY parsing, recording,
CSV, paths, text helpers) was extracted into small sibling modules so it's
independently unit-testable. See the [Code map](#code-map).

## The key design decision: metadata is decoupled from playback

This is the most important thing to understand.

`just_audio` exposes an `icyMetadataStream`, but **it is only populated on
Android/iOS/macOS**. On Windows and Linux the libmpv (media_kit) backend does
**not** feed `StreamTitle` into that stream. Since Windows is the primary target,
relying on it would mean the core "save the song" feature silently returns
nothing on the two main platforms.

So metadata is handled independently of the audio backend by **`IcyReader`**
(`lib/icy_reader.dart`):

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
(audio bytes are read just to reach the metadata; normally discarded). At ~128 kbps
that's negligible, and the payoff is identical behaviour on all three platforms.
Those same audio bytes are what the recorder taps — `IcyReader` forwards them
(batched, metadata stripped) through `onAudio`, and exposes the stream's
`contentType`/`bitrateKbps` from the response headers. See [Recording](#recording).

The byte-level state machine itself lives in a **pure `IcyParser`** (no I/O), so
it's unit-tested directly (`test/icy_reader_test.dart`); `IcyReader` is the thin
HTTP + lifecycle wrapper around it.

`IcyReader.start(url, …)` takes the `onTitle`/`onAudio`/`onStatus` callbacks as
parameters; the player passes closures from `_play`. Playback continues
regardless of whether metadata succeeds (it's best-effort and swallows errors).
Lifecycle hardening (added after a code review):

- **Staleness guard.** Fast station switches used to risk a stale connection
  overwriting a newer title. Now there are two layers: the player tags each
  `_play` with a `_playSession` id that its closures check, and `IcyReader`
  bumps an internal `_generation` on every `start`/`stop` so a superseded
  connection — and any pending reconnect timer — is inert.
- **Status, not one message.** `MetadataStatus`
  (idle/connecting/waitingForFirstTitle/unsupported/failed/active) is reported via
  `onStatus`. The now-playing box (`_nowPlayingText`) distinguishes "still
  connecting", "this station sends no `icy-metaint`" → *"doesn't provide track
  info"*, and a failed/dead connection → *"unavailable"* — instead of a blanket
  *"Waiting for track info…"*. A title is kept visible across a brief reconnect;
  once reconnects are exhausted it's shown as *"Track info unavailable — last: …"*.
- **Freshness gates Save/Record.** `_trackInfoFresh` is true only while the feed
  is `active`. **Save** and **Record** key off it (not merely a non-empty title),
  so a title left stale after the feed dies can't be saved or recorded; the
  Record button stays visible while `_recording` so an in-progress capture can
  still be cancelled.
- **Auto-reconnect.** If the metadata socket drops (`onDone`/`onError`) while the
  station is still current, it reconnects with bounded exponential backoff
  (~5 tries, capped at 30 s; a fresh title refills the budget). On a drop it
  reports `connecting` **immediately** (not only when the retry fires), so the
  freshness gate above engages for the whole backoff gap rather than lingering on
  `active`. This is what fixes the screen-off case where the next-track signal —
  and thus a recording's finalize — would otherwise never arrive.
- **Clean retune.** `_play` calls `await _icy.stop()` before `setUrl`, so the old
  station's reader is gone up front — even a failed retune can't leave it
  reconnecting in the background.

> Note: stream "listen" links are often `.pls`/`.m3u` playlists, not the audio
> itself. `just_audio` and `IcyReader` both need the **direct** stream URL. For
> example, SwissGroove's `listen.php` is an M3U pointing at
> `http://relay1.swissgroove.ch:80`, which is what the app actually uses.

## Code map

The non-UI logic was extracted from the once-single `main.dart` into small,
independently testable modules; `main.dart` keeps the UI and the player/session
controller. Modules:

| File | Owns |
|---|---|
| `lib/main.dart` | UI, `_PlayerPageState` (player/session controller), all page widgets. |
| `lib/icy_reader.dart` | `MetadataStatus`, pure `IcyParser`, `IcyReader`. |
| `lib/stream_recorder.dart` | `StreamRecorder` + filename/extension/unique-path statics. |
| `lib/storage_paths.dart` | `isDesktop`, `recDirKey`, `recordingsDir`, `savedTracksFile`, `historyFile`, `listRecordings`, `isAudioFile`. |
| `lib/radio_browser.dart` | `RadioBrowserStation`, pure `parseRadioBrowserStations`, `searchRadioBrowser` (online station-search backend). |
| `lib/csv_utils.dart` | `parseCsv` / `csvField`. |
| `lib/track_utils.dart` | `splitArtistTitle`, `fmtDateTime`, `fmtDuration`. |
| `test/` | Unit tests for the modules above. |

Key symbols:

| Symbol | Role |
|---|---|
| `main()` | Inits the desktop audio backend; on desktop restores saved window size via `window_manager` before showing the window. |
| `RadioApp` | `MaterialApp` — dark Material 3 theme (teal seed), debug banner off. |
| `Station` | `{name, url}` value object with `toJson`/`fromJson`. |
| `_defaultStations` | The seed list used on first launch only (mirrors `radios-selection.csv` at the repo root). |
| `PlayerPage` / `_PlayerPageState` | The main screen. Owns the `AudioPlayer`, the `IcyReader`, the station list, volume, and (via `WindowListener`) window-resize persistence. `_recordHistory` logs each played song (see [Play history](#play-history)). |
| `_StationTile` | A station row that reveals its edit + delete buttons only on hover (`MouseRegion`). |
| `_actionTile` | The dimmed/italic list rows for add / import / export at the end of the station list. |
| `_StationSearchPage` | The online station-search screen (Radio Browser keyword search, multi-select, favicons) opened by "Add a new radio station…"; its pencil action opens the manual `_StationDialog`. See [Online station search](#online-station-search-radio-browser). |
| `_searchBar` / `_openSearch` / `_closeSearch` / `_onPageKey` | The type-to-search station filter (see [Filtering](#filtering--type-to-search)). |
| `_importStations` / `_exportStations` | Import/export the station list as a `name,url` CSV via `file_picker`. |
| `_StationDialog` | Name + URL + colour-picker dialog; returns a `Station`. Pre-fills from `initial` to edit (vs. add). |
| `_ColorSwatch` | Reusable round colour chip (accent picker + station colour picker). |
| `_TrackListPage` / `SavedTrack` | The shared sortable/searchable table screen, used for **both** saved tracks and play history (parameterized by `title` / `fileResolver` / `emptyMessage` / `shareSubject` / `isHistory`). `_export` shares the CSV (share sheet on mobile, reveal-in-folder on desktop); `_historyControls` adds the count + logging toggle when `isHistory`. |
| `IcyParser` | Pure byte-level ICY state machine (no I/O); unit-tested. |
| `IcyReader` | HTTP + lifecycle wrapper around `IcyParser`: forwards audio bytes via `onAudio`, reports `contentType`/`bitrateKbps` and `MetadataStatus`, and auto-reconnects a dropped metadata socket. |
| `StreamRecorder` | Buffers the live audio to a temp file and finalizes a recording to `Artist - Title.<ext>` (see [Recording](#recording)). |
| `_SettingsPage` | The combined Settings screen: appearance (accent color) + recording prefs (buffering, buffer size, lead-in, output folder). |
| `accentColor` | Top-level `ValueNotifier<Color>` for the Material 3 seed; `RadioApp` rebuilds `MaterialApp` on change so the accent applies live. |
| `_RecordingsPage` | The recordings library — lists/plays the files in the output folder with never-stops / randomize / skip / export (see [Recordings library](#recordings-library)). |
| `recordingsDir()` / `listRecordings()` / `isAudioFile` | Locate the recordings folder (shared by the recorder + library) and list its audio files. |
| `savedTracksFile()` / `historyFile()` | Resolve the two CSV paths (`radio_saved_tracks.csv` / `radio_history.csv`). |
| `splitArtistTitle` | Splits a raw ICY `"Artist - Title"` string; shared by save, history, and recording filenames. |
| `parseCsv` / `csvField` | RFC-4180 CSV read/write (no dependency). |
| `_fmtDateTime` | Formats the ISO timestamp as `YYYY-MM-DD HH:MM`. |

## Data & persistence

- **`shared_preferences` keys:**
  - `volume` (double, 0.0–1.0)
  - `stations` (JSON string — array of `{name, url}`)
  - `win_w`, `win_h` (doubles)
  - `accent_color` (int ARGB, default teal `0xFF009688` — the Material 3 seed)
  - `history_logging` (bool, default `true` — whether the player logs to history)
  - `rec_buffering` (bool, default `true` — buffer the stream; off ⇒ no Record button)
  - `rec_buffer_mb` (int, default `35`, capped `128` — buffer cap / rewind window)
  - `rec_lead_seconds` (int, default `60`; -1 = whole buffer — manual-recording lead-in cap)
  - `rec_dir` (string, optional — recording output folder; absent ⇒ Downloads)
  - `rec_never_stops` (bool, default `false` — recordings library auto-advances)
  - `rec_randomize` (bool, default `false` — recordings library shuffles)
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
- **Per-station colour:** `Station.color` (optional ARGB int) is set in the
  edit/add dialog via a "Default" chip + preset swatches, saved in the `stations`
  JSON, and used by `_StationTile` to tint the icon + name — for tagging stations
  by genre or flagging favourites. It's not part of the `name,url` CSV (a local
  visual tag only).
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

### Online station search (Radio Browser)

The **"Add a new radio station…"** row no longer opens the manual dialog
directly — it pushes **`_StationSearchPage`**, which lets the user search the
free, no-key **[Radio Browser](https://www.radio-browser.info) API** by keyword,
tick one or several results, and add them at once. The page pops a
`List<Station>` and `_addStation` merges it with the **same `Set.add`
non-destructive dedup** as import. The app-bar **pencil** on that page opens the
classic manual `_StationDialog` and pops its single result through the same path,
so the manual flow still exists.

The network/parse logic lives in **`lib/radio_browser.dart`** (UI-free, so the
parser is unit-tested in `test/radio_browser_test.dart`):

- `searchRadioBrowser(query)` does a `GET /json/stations/search?name=…&hidebroken=true&order=votes&reverse=true`
  over a **new `dart:io HttpClient`** (no `package:http`; same primitive as
  `IcyReader`). It tries `all.api.radio-browser.info` (round-robin DNS) then named
  mirrors (`de1`/`de2`/`nl1`) on failure, sends a `ez_tunein/<version>`
  User-Agent (the API asks for a "speaking" agent), and times out at ~8 s.
- `parseRadioBrowserStations(body)` (pure) decodes the JSON array, tolerates the
  API's mixed field types, and drops rows with no name or no playable URL.
- Each result maps to a `Station` using **`streamUrl`** — `url_resolved` (the
  API's already-unwrapped **direct** stream URL, exactly what this app requires)
  falling back to `url`. So online results never need playlist unwrapping.

Result rows show the station favicon (`Image.network` with a radio-icon fallback
for missing/broken images), the name, and a `country · codec · bitrate · tags`
subtitle; rows whose URL is already in the list are disabled and marked "Added".

### Import / export the station list

Two dimmed action rows sit at the end of the station list (after "Add a new
radio station…"), built by `_actionTile`. Both use **`file_picker`** for the
native dialogs:

- **Export** (`_exportStations`): builds a `name,url` CSV (header row +
  `csvField`-escaped rows) and opens a save dialog. On desktop `saveFile`
  returns the chosen path and we `writeAsString`; on mobile there's no writable
  path, so we hand `file_picker` the `bytes` and it writes the file itself.
- **Import** (`_importStations`): opens a file picker (`withData: true` so mobile
  gets the bytes), reads the file (`bytes` on mobile, `path` on desktop), parses
  it with the shared `parseCsv`, and **merges non-destructively** — it skips any
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
  `splitArtistTitle` + `csvField` and the saved-tracks header; writes are
  best-effort (errors swallowed), like metadata. The history is **unbounded** —
  it grows one row per song until cleared — so the view loads it lazily (see
  *Paged rendering* below).
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
- **Paged rendering.** History is unbounded, so the view doesn't build every row
  on open. The whole CSV is still parsed up front (cheap — and offloaded to a
  background isolate via `compute` once it's over 256 KB, so the UI thread stays
  responsive), but only a window of `_pageSize` (200) rows is built into widgets.
  The window grows by a page when you scroll within ~300 px of the bottom
  (`_onScroll` → `_showMore`) or tap the **Show more** footer, and resets to the
  first page whenever the filter or sort changes the ordering/membership
  (`_resetWindow`, which also jumps back to the top). Both layouts share one
  `ScrollController`. This keeps open-time and memory flat regardless of how large
  the history grows.

### Recording

You can save a whole song — *including the part that already played* before you
hit Record — to a file. The trick is that the player is always buffering the
current track, so "record" just commits the buffer and keeps going.

- **Why it's lossless and dependency-free.** Icecast/Shoutcast bytes are already
  compressed audio (usually MP3, sometimes AAC) at the station's fixed bitrate.
  `IcyReader` already reads every audio byte to reach the metadata; instead of
  discarding them it forwards them via `onAudio`, and the recorder writes them to
  disk **verbatim**. No decoding, no re-encoding, no codec package — and therefore
  no way to *change* the bitrate (it's always the stream's own). The file
  extension comes from the response `Content-Type` (`audio/mpeg` → `.mp3`,
  `audio/aac`/`aacp` → `.aac`, else `.mp3`).
- **The buffer (`StreamRecorder`).** While a stream plays and buffering is on, the
  current track's audio is appended to a temp file in `getTemporaryDirectory()`.
  It's a **segmented ring buffer**: audio appends to an active segment file and a
  new segment is rolled when it fills (segment size ≈ ⅛ of the cap, clamped to
  1–16 MB). Until you arm recording, the *oldest whole segment* is dropped — an
  O(1) file delete, no read — once the remaining segments still cover
  `rec_buffer_mb` MB, so the retained "rewind" window stays in `[cap, cap +
  segment)`. Per-chunk writes are **synchronous** (`RandomAccessFile.writeFrom
  Sync`) so the stream listener stays in order; like metadata, errors are
  swallowed. This deliberately replaced an earlier single-file design that
  enforced the cap by reading ~`cap` bytes into RAM and rewriting the file — a
  recurrent multi-MB allocation + UI hitch on the isolate (worst for someone
  doing something demanding alongside, e.g. gaming). The ring buffer has no such
  spike: trimming is just a delete. `rec_buffer_mb` is still capped at
  `_recBufferMbMax` (128 MB; an old saved value above it is clamped on read) to
  bound disk use and the one-time finalize copy.
- **Arm → finalize.** `_toggleRecord` calls `arm()`, capturing the title/station
  and marking the buffer to be kept regardless of the cap (dropping is paused, so
  the whole song is retained). The recording is finalized to
  `<output>/Artist - Title.<ext>` (de-duped with ` (2)`) when the track changes
  (`onTrackChanged`), the stream stops (`_stop`), or the station is switched
  (`_play` finalizes the old one first). Finalize concatenates the live segments
  in order, streamed in 1 MB chunks (bounded memory); a one-segment song takes a
  rename fast path. A success snackbar names the saved file.
- **Serialized lifecycle.** `startBuffering`/`onTrackChanged`/`onStreamStopped`/
  `dispose` run through a `_runExclusive` queue, so a metadata-driven finalize
  (track change) can't interleave with `_stop`'s finalize and double-move or
  delete the same segments — overlapping calls run one-after-another, and the
  second sees `_armed == false` and becomes a clean no-op. Public methods call
  private bodies (`_startBuffering`, …) so the queue doesn't deadlock on itself.
  `addAudio` is synchronous and unqueued; it no-ops while there's no open active
  segment (i.e. mid-teardown).
- **Track-change detection.** Driven by the same `IcyReader.onTitle` as history,
  via `_handleTrackChange`, which dedups on `_lastRecTitle` (the reader re-emits
  each tick) and **skips the first title of a session** — that's the initial song,
  whose buffer is already running from `_play`, so resetting it would throw away
  the start. Subsequent changes finalize + reset.
- **One at a time / cancel.** Only one song records at once; tapping Record again
  `cancel`s (disarms, discarding the in-progress file but keeping the buffer so you
  can re-arm). The button is hidden entirely when `rec_buffering` is off. While a
  recording is armed the now-playing card gets a thin, diffused red neon glow
  (`_recording`).
- **Title-less stations (manual recording).** A station with no `icy-metaint`
  (e.g. FIP) sends no titles, and historically fed the recorder no audio either.
  Now `IcyReader.start(bufferWithoutMetadata:)` — set from `_recBuffering` — keeps
  that connection open and forwards the raw body to `onAudio` (`_listenRaw`), so
  the buffer fills (the second download only runs when buffering is on, so we
  don't double-download a station we'll never record). `_canRecord` then allows
  recording when there's a fresh title **or** the station is `unsupported`. Such a
  recording is **manual** (`_manualRecording`): with no track change to finalize
  on, tapping Record again **saves** (`_saveManualRecording` → `onTrackChanged`)
  rather than cancelling, and the file is named `<station> <YYYY-MM-DD HH.MM>`
  (no `Artist - Title`). It still auto-saves if you stop or switch stations.
  Toggling `rec_buffering` while on such a station restarts the reader so the raw
  stream starts/stops to match.
- **Lead-in cap (`rec_lead_seconds`).** A title-less station has no song
  boundary, so the buffer could otherwise prepend many minutes of unrelated audio
  to a manual recording. The setting (slider: 0/30s/1/2/3/4 min/Max, default 1 min;
  -1 = whole buffer) caps how much pre-tap audio is kept. The player turns seconds
  into bytes via the stream bitrate (`_icy.bitrateKbps`, fallback 128 kbps) and
  passes `leadInBytes:` to `arm`; the recorder tracks each segment's logical
  `startOffset` against a monotonic `_writtenBytes` counter and, at finalize,
  emits from `_recordStartOffset = max(oldestRetained, written − leadInBytes)`
  (skipping the front of the first segment as needed). **Titled recordings pass
  `null`** (whole buffer) — their buffer already begins at the song's start, so
  this never truncates a real song.
- **Staying alive in the background (Android).** Both playback **and** the
  recording path — `IcyReader`'s HTTP socket loop plus the track-change detection
  that finalizes a recording — run on the **main isolate**. With the screen off
  and the app backgrounded, Android's Doze/App-Standby freezes that isolate:
  playback dies (after ExoPlayer's buffer coasts a bit) and no new stream bytes
  are parsed, so a recording never stops (it finalizes late, or as one giant file,
  when you wake the screen). The fix is a **foreground service**
  (`flutter_foreground_task`) that runs the whole time a station is active —
  raised in `_play`, torn down in `_stop`. A single method, `_syncPlaybackService`,
  drives it: when `_current != null` it starts (or `updateService`-refreshes) a
  `mediaPlayback` service with a silent ongoing notification (wake-lock +
  Wi-Fi-lock) showing the station, the now-playing title (or "Recording: …" while
  armed), and a **Stop** button; when `_current` is null it stops the service. It's
  re-called on track change, record arm/cancel, and the buffering toggle so the
  notification text tracks state. The foreground priority keeps the main isolate
  un-frozen, so playback continues and the recording loop still sees the next-track
  signal with the screen off.
  - **The Stop button** is the only transport control — live radio has no
    meaningful pause (you'd just resume to live). Button taps arrive in a separate
    **task-handler isolate** (`flutter_foreground_task` runs notification callbacks
    there): the top-level `_foregroundTaskCallback` registers
    `_PlaybackServiceHandler`, whose `onNotificationButtonPressed` relays the id via
    `FlutterForegroundTask.sendDataToMain('stop')`. The UI isolate listens with
    `addTaskDataCallback(_onForegroundData)` (registered in `initState`, removed in
    `dispose`) and calls `_stop`. Tapping the notification body calls `launchApp()`.
    Set up once in `main()` with `initCommunicationPort()` + `init(...)`
    (`ForegroundTaskEventAction.nothing()` — no periodic event; the handler exists
    only to relay taps).
  - All of this is **Android-only** (`Platform.isAndroid`) and best-effort —
    playback and recording still work in the foreground if the service can't start.
    We use a standalone service rather than `just_audio_background` because that
    package permits only one `AudioPlayer` in the whole app, which would crash the
    recordings library's separate player; it also avoids migrating playback to
    `AudioSource`/`MediaItem`. The trade-off vs. a true `MediaSession`: no rich
    media-card UI and no headset/Bluetooth media-button control.
  - This does not fix the *other* limitation of metadata-driven boundaries —
    stations that announce the next title early, or the player's buffer lag, can
    still make a cut feel a few seconds early; that's inherent to ICY metadata
    without decoding the audio.
- **Settings (`_SettingsPage`).** One combined screen (gear icon on both the
  player and the recordings view), with **Appearance** first, then recording.
  - **Accent color.** The Material 3 seed lives in a top-level
    `ValueNotifier<Color> accentColor`; `RadioApp` wraps `MaterialApp` in a
    `ValueListenableBuilder` on it, so a pick re-themes the whole app live (the
    sliders/switches/buttons — including the picker's own sliders — recolor as you
    drag). The page offers preset swatches plus R/G/B sliders for any color, using
    the current color API (`Color.fromARGB` / `.toARGB32()` / `.r`·`.g`·`.b`);
    `main()` restores the saved `accent_color` before the first frame.
  - **Recording.** Writes the `rec_*` prefs directly (same single-cached-instance
    trick as the history toggle). On pop the player calls `_applyRecordingPrefs`,
    which pushes the new cap/enabled/lead-in state into the recorder and
    starts/stops live buffering if the toggle flipped. The buffer-size slider carries a `_bufferGuide` caption — the MB
  cost of one minute of MP3 at 128/256/320 kbps, and how many minutes the chosen
  size rewinds at each — so the number isn't an opaque "MB". Output folder
  defaults to `getDownloadsDirectory()` on desktop
  (chosen via `file_picker`'s `getDirectoryPath`), falling back to the app
  documents dir; on Android it always uses the app folder (an arbitrary user folder
  needs SAF/MediaStore — not done).

### Recordings library

A small local jukebox for the recorded files (`_RecordingsPage`, opened from the
`library_music` app-bar icon).

- **Its own player.** The view creates a **separate** `AudioPlayer` from the radio's
  `_player`, applies the saved `volume`, and `dispose()`s it when you leave — so
  playback is **scoped to the view** (no shared state). Starting a song first calls
  the `stopRadio` callback (the player's `_stop`) **once** (`_radioStopped` guard),
  so the radio and a recording never sound at the same time.
- **Listing & metadata.** `listRecordings()` scans `recordingsDir()` (the same
  folder the recorder writes to) and keeps files whose extension passes
  `isAudioFile`, sorted by name. There are no audio tags — artist/title come purely
  from the filename via `splitArtistTitle` (recordings are `Artist - Title.ext`); a
  file not in that shape shows its whole name as the title.
- **Playback & auto-advance.** `_playAt` uses `setFilePath` + un-awaited `play()`
  (same endless-stream gotcha caveat — though these are finite, completion is read
  from `playerStateStream`, not by awaiting `play()`). When a file completes and
  **Never stops** (`rec_never_stops`) is on, `_advance()` plays the next; **Randomize**
  (`rec_randomize`) picks a random index instead (re-rolling once to avoid an
  immediate repeat). The **skip** button uses the same next-index logic, so it
  shuffles too when Randomize is on.
- **Export.** Writes a two-column `artist,title` CSV through the same `file_picker`
  `saveFile` flow as the station export (desktop writes the path; mobile gets the
  bytes). The list is loaded fresh each time the view opens (`listRecordings`).
  A **folder** icon (`_openFolder`, desktop only) opens the recordings directory in
  the OS file manager. Each row also has an overflow menu (`_deleteFile` with a
  confirm dialog, and `_shareFile` via `share_plus` on mobile) so files can be
  freed/moved in-app — important on Android, where the folder isn't browsable.
  Deleting the playing track stops it first and fixes up `_index`.
- **Background playback (Android).** Like the radio, the recordings view gets the
  foreground-service treatment so playback survives the screen turning off —
  `_syncRecordingsService` (driven off the player-state stream) raises/updates the
  `mediaPlayback` service while a file is loaded and stops it when nothing is. Since
  these are **finite files**, its lock-screen notification has richer controls than
  the radio's Stop-only: **Pause/Play** (the button label tracks state), **Skip**
  (next, honouring Randomize), and **Stop**. The buttons use `rec_`-prefixed IDs
  (`rec_toggle`/`rec_skip`/`rec_stop`) so the radio page's still-registered
  `_onForegroundData` ignores them; the recordings page registers its own
  `_onForegroundData` in `initState` and removes it (and stops the service) in
  `dispose`. The two pages share the single service instance without clashing because
  the radio is always stopped (`_current == null`) while recordings playback is
  active. Android-only and best-effort, like the radio path.

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
  latter). Setup, the `play()` gotcha, and release signing (done — upload keystore
  via CI secrets) live in [`android-build.md`](./android-build.md).

## Tests & CI

- **Unit tests** (`test/`) cover the extracted, pure logic: the `IcyParser` byte
  state machine (metadata split across chunks, audio split exactly at the
  `metaint` boundary, zero-length blocks, `StreamTitle` with/without `StreamUrl`,
  no empty titles), the CSV read/write round-trip, the recorder's filename
  sanitisation / extension / unique-path helpers, the segmented ring buffer
  (rolling, dropping, ordered finalize, cancel, and serialized overlapping ops —
  the recorder's segment dir/size are injectable so this runs without a device),
  and the track-text helpers. `IcyReader`'s connection lifecycle is covered by an
  integration test (`test/icy_reader_lifecycle_test.dart`) driving a loopback
  `HttpServer`: unsupported (no `icy-metaint`), first-title → `active`, a dropped
  feed → `connecting` *immediately*, and exhausted-reconnects → `failed`
  (the backoff is injectable via `reconnectDelay` so it runs in milliseconds). Run with `~/flutter/bin/flutter test`. The UI is not
  widget-tested (it needs audio / a display this environment lacks).
- **CI** (`.github/workflows/ci.yml`) runs `dart format --set-exit-if-changed` +
  `flutter analyze` + `flutter test` + a debug Linux build on every push/PR. The
  **release** workflow gates on the same `verify` job (format + analyze + test)
  before it builds any platform artifacts, so a broken or unformatted commit can't
  be tagged into a published release. Run `dart format lib test` before pushing.

## Known limitations / possible next steps

- Stations can be added/removed/edited but not **reordered**.
- No URL validation beyond non-empty; a bad URL surfaces as a "Could not play"
  snackbar.
- The saved-tracks and history views are snapshots (no live refresh while open);
  the history entry count likewise reflects open-time.
- Play history is **unbounded** — it grows until the user clears it (there's a
  logging on/off toggle, but no automatic size cap or retention window). The view
  now loads it lazily (paged rendering + off-thread parse), so a large history is
  cheap to open; a retention cap is still a possible future addition.
- **Recording** keeps the stream's native bitrate/codec (no transcoding, by
  design). You can only capture from when you tuned in (joining mid-song records
  the remainder). On **Android** recordings save to the app folder — picking an
  arbitrary folder (e.g. Downloads) needs SAF/MediaStore plumbing, not yet done.
  Stations that send no ICY metadata have no track boundaries, so recording is
  inert there.
- The application ID is `io.github.flochrislas.eztunein` (Android `applicationId`
  + `namespace`, and the Linux GTK `APPLICATION_ID` — which determines the
  `shared_preferences` directory). The Dart **package** and the on-disk **binary**
  are named `ez_tunein` (`name:` in `pubspec.yaml`; `BINARY_NAME` in the Linux /
  Windows CMake). The launcher/window title is `EZ-TuneIn` (Android `android:label`)
  / `EZ-TuneIn Radio` (desktop window title).
- `album` column is always blank for ICY sources; a per-station JSON API (e.g.
  SomaFM's) could fill it in.
