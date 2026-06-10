# EZ-TuneIn Radio

A minimalist, lightweight internet radio player. Tune into your favourite online
radio stations, see what's playing right now, and save the songs you love — all
from one clean, dark interface.

Runs on **Windows**, **Linux**, and **Android**.

## Features

- **Play internet radio** — stream Icecast/Shoutcast stations such as SomaFM's
  Groove Salad, Drone Zone, or SwissGroove.
- **Live "now playing"** — see the current artist and track update as the music
  changes.
- **Save the songs you like** — one click logs the current track.
- **Saved tracks view** — browse everything you've saved in a sortable table of
  **date · radio station · artist · title**. Click a column header to sort by it,
  click a row to copy `Artist - Title` to your clipboard, or wipe the list with
  **Clear all**.
- **Manage your stations** — add a station with the **+** button, or hover a
  station and click the trash icon to remove it. Your list is remembered between
  launches.
- **Remembers your setup** — volume and (on desktop) the window size persist
  across restarts.

Your saved tracks are written to `radio_saved_tracks.csv` — on desktop that's
your **Documents** folder, so they're easy to open in a spreadsheet (on Android
it's an app-private file you browse via the in-app saved-tracks view).

## Install & run

You'll need the [Flutter SDK](https://docs.flutter.dev/get-started/install). Once
it's installed, from a clone of this repo:

```
flutter pub get
flutter run        # add -d linux or -d windows to target a specific device
```

Platform-specific setup is below.

### Linux

1. **Install Flutter** (if not already). Easiest:
   ```
   sudo snap install flutter --classic
   flutter --version      # first run downloads the Dart SDK
   ```
   (Or follow https://docs.flutter.dev/get-started/install/linux for the tarball method.)

2. **Install libmpv** — the desktop audio backend wraps it:
   ```
   sudo apt install -y libmpv-dev mpv
   ```

3. **Run it:**
   ```
   flutter pub get
   flutter run -d linux
   ```

**Where settings are stored:** your volume, station list, and window size live in:
```
~/.local/share/io.github.flochrislas.eztunein/shared_preferences.json
```
Delete that file (or individual keys like `win_w` / `win_h`) to reset to
defaults — e.g. to get a true "first run" window size again.

### Windows 11

1. **Git for Windows** — https://git-scm.com (Flutter uses it under the hood).
2. **Visual Studio 2022** (Community edition is fine) with the
   **"Desktop development with C++"** workload. This is required to *build*
   Windows desktop apps — VS Code alone is not enough.
3. **Flutter SDK** — clone the stable branch (or download the ZIP from
   https://docs.flutter.dev/get-started/install/windows):
   ```powershell
   git clone --depth 1 -b stable https://github.com/flutter/flutter.git C:\src\flutter
   ```
4. **Add to PATH:** add `C:\src\flutter\bin` via *Settings → Edit environment
   variables for your account → Path → New*, then open a fresh terminal.
5. **Enable Developer Mode** — Flutter needs symlink support to build with
   plugins. Open *Settings → System → For developers* and turn on **Developer
   Mode** (or run `start ms-settings:developers`). Without it the build fails
   with *"Building with plugins requires symlink support. Please enable
   Developer Mode..."*. From an **admin** PowerShell you can also enable it with:
   ```powershell
   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1
   ```
6. **Run it** (`media_kit` bundles its own libs on Windows — no libmpv needed):
   ```powershell
   flutter pub get
   flutter run -d windows         # or: flutter build windows
   ```

### Android

Building for Android needs the Android SDK and a **JDK 17+** (not the SDK's GUI
IDE). On Linux, two helper scripts automate the one-time setup:

```bash
bash script/android-sdk-install.sh      # installs the SDK + points Flutter at it
sudo bash script/android-udev-fix.sh    # USB device permissions (phone plugged in)
```

Then enable **USB debugging** on the phone, plug it in, and:

```bash
flutter devices                          # confirm the phone is listed
flutter run                              # build, install, launch
flutter build apk --release              # or produce a release .apk
```

Full walkthrough, gotchas, and release-signing notes:
[`doc/android-build.md`](doc/android-build.md).

## Adding / changing stations

Use the **+** button in the app to add a station (name + direct stream URL), and
hover a station to reveal a delete button. Your list is saved between launches.
The defaults in `_defaultStations` (top of `lib/main.dart`) only seed the very
first launch.

> Stream URLs must be **direct** — not `.pls`/`.m3u` playlist links.

## Documentation

- [`doc/implementation-notes.md`](doc/implementation-notes.md) — how it's built.
- [`doc/tech-stack.md`](doc/tech-stack.md) — why this stack was chosen.
- [`doc/android-build.md`](doc/android-build.md) — Android SDK setup, device
  setup, and Android-specific gotchas.

## License

Released under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE).
