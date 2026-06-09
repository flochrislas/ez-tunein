# Tech Stack Notes — Internet Radio Player

App goal: minimalist, lightweight player that (1) plays internet radios (Groove Salad / SomaFM, SwissGroove, etc.) and (2) saves the current song's metadata (artist / song / album, ideally) to a file at the click of a button. Windows first, then Linux and Android.

## Recommendation: Flutter + `just_audio`

For minimalist, lightweight, Windows-first, then Linux **and Android**, this is the clearest winner.

> **Correction (2026-06-09):** the claim below that "`just_audio` parses ICY metadata for you" is **only true on Android/iOS/macOS** (ExoPlayer/AVPlayer). On **Windows and Linux desktop**, `just_audio` uses the `just_audio_media_kit` (libmpv) backend, which does **not** populate `icyMetadataStream`. Since Windows is the primary target, the app instead uses a small hand-written ICY reader (open the stream with `Icy-MetaData: 1`, parse `StreamTitle`) that behaves identically on all three platforms. Playback still uses `just_audio`. See `lib/main.dart` (`IcyReader`).

### The thing that actually decides this: where does the song metadata come from?

Playing the stream is trivial on any platform. The real constraint is capturing "artist / song / album," and there are only two sources:

1. **ICY (Shoutcast/Icecast) inline metadata** — the standard. You send the header `Icy-MetaData: 1` when connecting, and the server interleaves a `StreamTitle="Artist - Track"` field into the audio stream every ~16 KB. This is what Groove Salad, SwissGroove, etc. emit.
   - **Caveat:** ICY almost never includes the **album**. You typically only get `Artist - Title`. Album is usually not available from the raw stream.

2. **Station-specific JSON APIs** — e.g. SomaFM publishes now-playing/song-history JSON per channel. These sometimes include album art and more fields. But every station's API is different, so this doesn't generalize.

So realistically: **artist + song name = reliable; album = best-effort** (only when a station exposes it). Worth knowing before you build.

### Why Flutter wins here

- **`just_audio` parses ICY metadata for you** — it exposes an `icyMetadata` stream, so you get `StreamTitle` updates without hand-rolling the ICY protocol. This is the single biggest reason; on most other stacks you'd implement the byte-interleaving parser yourself.
- **One codebase → Windows, Linux, Android** (and macOS/iOS/web for free). This directly matches the roadmap.
- Reasonably light, simple UI, fast to build a one-screen app.

A minimal v1 is genuinely small: a station dropdown, play/stop, a "Save" button that appends the current `StreamTitle` + timestamp to a text/CSV file.

### Honest alternatives

| Stack | Verdict |
|---|---|
| **PWA / plain web `<audio>`** | Tempting and lightest, but **don't** — browsers can't read ICY metadata (CORS + the stream format block it). You'd lose your core feature. |
| **Tauri (Rust + webview)** | Tiny binaries, great on Win/Linux. But you'd implement audio + ICY parsing yourself in Rust, and its Android support is newer/rougher. More work for the same result. |
| **Python + GUI (Qt/Tkinter) + `python-vlc` or raw socket** | Fast to prototype on desktop, but heavy/awkward to package, and **no real Android path**. Only good if you abandon the Android goal. |
| **.NET MAUI** | Windows + Android well-supported, Linux only via community. Heavier than Flutter, no Linux first-party. |

### Suggested minimal stack to start

- **Language/Framework:** Dart + Flutter
- **Audio + metadata:** `just_audio` (use its `icyMetadata` stream for `StreamTitle`)
- **Saving the file:** `path_provider` + plain `dart:io` file append (CSV: `timestamp, station, artist, title`)
- **Parsing:** split `StreamTitle` on `" - "` into artist/title; store raw string as fallback

If you'd later want album/art reliably, layer in the SomaFM JSON API for SomaFM channels specifically.
