# Android Build

How to build and run **EZ-TuneIn Radio** on Android, and the gotchas that bit us
getting there. Android works today (audio + live metadata + save/view tracks all
verified on a physical Pixel 9a, Android 16 / API 36).

The dev machine is **Linux (Ubuntu 24.04)** with **no Android Studio** — just the
command-line SDK. Two helper scripts in [`../script/`](../script/) automate the
one-time setup:

| Script | What it does |
|---|---|
| `android-sdk-install.sh` | Downloads the Android command-line tools, installs the SDK packages, accepts licenses, and points Flutter at the SDK **and** a modern JDK. |
| `android-udev-fix.sh` | Grants your user USB access to the phone (fixes "adb: insufficient permissions / missing udev rules?"). Needs `sudo`. |

## One-time setup

### 1. Install the SDK

```bash
bash script/android-sdk-install.sh
```

This installs into `~/Android/Sdk`:

- `platform-tools` (adb)
- `platforms;android-36`, `build-tools;36.0.0` — matches the AGP 9 template

…then runs `flutter config --android-sdk` and `flutter config --jdk-dir`.

> **JDK gotcha:** the system default `java` here is **8**, which Gradle 9 / AGP 9
> reject ("requires JDK 17 or later"). The toolchain needs a **JDK 17+**; we use
> `/usr/lib/jvm/jdk-25`. The script auto-selects a 17+ JDK (ignoring an `8`
> pointed at by `JAVA_HOME`) and registers it with `flutter config --jdk-dir`, so
> Flutter uses it for Gradle without changing the system default. Confirm with
> `flutter doctor -v` — the Android line should say "Java binary at … jdk-25 …
> specified in your Flutter configuration" and "All Android licenses accepted".

The project pins recent build tooling (see `android/`): **Gradle 9.1.0**,
**AGP 9.0.1**, **Kotlin 2.3.20** — which is why JDK 25 is the right match.

### 2. Connect a phone

1. On the phone: enable **Developer options** (tap *Build number* 7×), then turn
   on **USB debugging**.
2. Plug it in over USB and approve the **"Allow USB debugging?"** prompt.
3. On Linux, the device first shows as `unsupported` with
   `adb: insufficient permissions for device: missing udev rules?` — the USB node
   is owned by root. Fix it:
   ```bash
   sudo bash script/android-udev-fix.sh
   ```
   Then **unplug/replug** the phone. It writes a udev rule keyed on the phone's
   USB vendor id (auto-detected from its serial via `/sys`) granting access via
   the `uaccess` tag + `plugdev` group, and restarts the adb server.
4. Verify:
   ```bash
   ~/flutter/bin/flutter devices    # phone shows a real model name
   ```

## Build & run

```bash
~/flutter/bin/flutter run                       # build, install, launch (debug)
~/flutter/bin/flutter run -d <serial>           # if multiple devices attached
~/flutter/bin/flutter build apk --release       # a release .apk artifact
```

The **first build is slow** (Gradle downloads dependencies, compiles native
code); later builds are fast. While `flutter run` is attached: `r` = hot reload,
`R` = hot restart, `q` = quit.

### Reading device logs

The default logcat is drowned in `CCodec`/`MediaCodec` audio-decoder chatter.
Filter to just the app's Dart output:

```bash
~/Android/Sdk/platform-tools/adb logcat -c          # clear the buffer
~/Android/Sdk/platform-tools/adb logcat -s flutter:* # only `debugPrint`/`print`
```

## App configuration that Android needs

In `android/app/src/main/AndroidManifest.xml`:

- **`<uses-permission android:name="android.permission.INTERNET"/>`** — debug
  builds get this automatically, but release/profile builds need it declared.
- **`android:usesCleartextTraffic="true"`** — some relays (e.g. SwissGroove's
  `relay1.swissgroove.ch:80`) are plain HTTP, which Android blocks by default
  since API 28. Without this the HTTP stations fail to play (HTTPS ones, like
  SomaFM, work either way).

## The `play()` gotcha (Android-specific bug we hit)

`just_audio`'s `AudioPlayer.play()` returns a `Future` that completes only when
playback **ends** (or is paused/stopped). For an endless radio stream it never
completes — so `await player.play()` blocks forever.

On the desktop **media_kit** backend `play()` returned promptly, so this was
invisible on Linux/Windows. On Android (**ExoPlayer**) it blocked `_play()`,
leaving the UI stuck on "Connecting…" and the metadata reader unreached. The fix
in `_play()` is to **not await** `play()`:

```dart
await _player.setUrl(station.url);
unawaited(_player.play());   // NOT: await _player.play();
```

The lesson: never `await` `just_audio.play()` for a live/endless source.

## Saved tracks on Android

The CSV (`radio_saved_tracks.csv`) is written to the app's documents directory
via `getApplicationDocumentsDirectory()`. On desktop that's the user's real
**Documents** folder; on Android it's an **app-private** directory that isn't
browsable from a file manager.

To get the file **off the device**, the saved-tracks view has a **Share** action
(`_export`, via the `share_plus` package). On mobile it opens the OS share sheet
— email, Quick Share to a PC, Drive, "Save to Files", etc. On desktop (where the
file is already in Documents) the same button instead copies the path and offers
to open the containing folder, since `share_plus` doesn't support file sharing on
Linux. Saving, viewing, and sharing tracks are all verified on Android and Linux.

## Background playback & recording (the screen-off freeze)

Both playback and recording run on the Flutter **main isolate**: just_audio drives
ExoPlayer, and recording reads the stream + detects song boundaries on a separate
HTTP connection (`IcyReader`). When the screen goes off and the app is
backgrounded, Android's **Doze / App-Standby** freezes that isolate — playback dies
(after ExoPlayer's buffer coasts a while) and no new stream bytes are parsed, so a
recording's track-change never fires (it finalizes late, or as one big file, when
you wake the screen).

The fix is a **foreground service** (`flutter_foreground_task`) that runs the whole
time a station is playing:

- `_syncPlaybackService` starts a `mediaPlayback` service (silent ongoing
  notification, wake-lock + Wi-Fi-lock) when you start a station, refreshes its
  text on track/recording changes, and stops it when you Stop. The foreground
  priority exempts the process from Doze, so **playback keeps going** and the
  recording loop still detects the next track with the screen off.
- The notification carries a **Stop** button (live radio has no useful pause).
  Taps are received in a background task-handler isolate
  (`_PlaybackServiceHandler.onNotificationButtonPressed`) and relayed to the UI
  isolate via `sendDataToMain`, where `_onForegroundData` calls `_stop`. Tapping
  the notification body re-opens the app.
- It's **Android-only** (`Platform.isAndroid`) and best-effort — if it can't start
  (e.g. notifications denied), playback/recording still work while foregrounded.

Manifest additions: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`,
`POST_NOTIFICATIONS`, `WAKE_LOCK`, and the
`com.pravera.flutter_foreground_task.service.ForegroundService` declaration with
`android:foregroundServiceType="mediaPlayback"`.

> We deliberately did **not** use `just_audio_background`: it allows only one
> `AudioPlayer` in the whole app, which would crash the recordings library (it
> owns a second player), and would force migrating playback to
> `AudioSource`/`MediaItem`. A standalone service avoids both. The trade-off is no
> true `MediaSession` — i.e. no rich media-card UI and no headset/Bluetooth
> media-button control.

This addresses the *background freeze*. It does **not** change the other limitation
of ICY metadata — some stations announce the next title a few seconds early, so a
cut can feel slightly early; fixing that would need decoding the audio (an
ffmpeg-class dependency we avoid on purpose).

## Release signing (done)

Release builds are signed with a real **upload keystore**. `build.gradle.kts` reads
`android/key.properties` (git-ignored, created by
[`script/android-signing-setup.sh`](../script/android-signing-setup.sh)) and uses
that signing config; CI recreates `key.properties` + the keystore from repository
secrets (`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` /
`ANDROID_KEY_ALIAS` — see [`releasing.md`](./releasing.md)). When `key.properties`
is absent (e.g. a fresh clone before secrets are wired) the build **falls back to
debug** signing so it still compiles. The release workflow verifies the published
APK is signed with the upload key, not debug.

_(The launcher label is `EZ-TuneIn` via the manifest's `android:label`; the Dart
package and binary are named `ez_tunein`.)_
