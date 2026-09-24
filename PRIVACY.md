# EZ-TuneIn Radio — Privacy Policy

_Last updated: 2026-09-19_

EZ-TuneIn Radio ("the app") is a free, open-source internet radio player
published by flochrislas under the GPL-3.0 licence. The source code is at
<https://github.com/flochrislas/ez-tunein>, so everything described here can be
verified.

**Short version: the app has no accounts, no analytics, no ads, no crash
reporting and no third-party tracking SDKs. It does not collect, store or sell
personal data. The only data that leaves your device is what is technically
required to play a radio stream or to search the public station directory.**

## Data that leaves your device

The app only makes network requests to do what you asked it to do:

1. **Playing a station.** When you tap a station the app connects directly to
   that station's stream server (a URL you added, imported, or picked from the
   directory). Like any HTTP client, the app sends the server your IP address and
   a `User-Agent` header identifying the app (`ez_tunein`). The stream operator's
   own privacy practices apply to that connection; the app does not send them
   anything else.
2. **Searching for stations.** The online search sends your keyword, your IP
   address and the app's `User-Agent` (`ez_tunein/<version>`) to the free,
   community-run **Radio Browser** directory (`api.radio-browser.info`, see
   <https://www.radio-browser.info>). No account or key is involved. Station
   logos shown in the results are loaded from the URLs the directory returns,
   over HTTPS only.
3. **Opening a link.** Tapping "Releases on GitHub" or "Privacy policy" in
   Settings opens that page in your browser. The app does not check for updates
   or contact GitHub on its own.

That is the complete list. The app never transmits your station list, listening
history, saved tracks or recordings anywhere.

## Data stored on your device

Everything below is stored locally, on your device only, and you can delete it
from within the app or by uninstalling it:

- **Settings** (volume, accent colour, recording preferences, window size).
- **Your station list**, including stations you added or imported.
- **Saved tracks**: song titles you explicitly saved with the Save button.
- **Play history**: the app logs the titles of songs it plays so you can look
  them up later. This is **on by default and can be turned off** from the
  History view. The log is kept in a local CSV file and is capped in size.
- **Recordings**: audio you explicitly recorded with the Record button. On
  Android these are kept in the app's private storage; on desktop they go to a
  folder you choose (default `Downloads/EZ-TuneIn`).

Sharing or exporting any of these (CSV export, "Share/move" of a recording) is
always an explicit action of yours, done through your operating system's share
or save dialog. The app has no cloud storage of its own.

**Android device backup.** Like most Android apps, the app's local data may be
included in the automatic device backup that Android performs to your Google
account (if you have that feature enabled). That backup is managed and encrypted
by Android, not by the app; see Google's documentation for how it is handled.

## Permissions

| Permission | Why |
|---|---|
| Internet | Connect to radio streams and the station directory. |
| Foreground service (media playback) | Keep the stream (and any in-progress recording) running with the screen off, with a media notification and lock-screen controls. |
| Notifications (Android 13+) | Show that media notification. |
| Wake lock, Wi-Fi state | Keep the device and Wi-Fi awake while a stream is playing in the background. |

No permission gives the app access to your contacts, location, camera,
microphone, photos, or files outside the ones described above.

## Children

The app is a general-audience radio player and is not directed at children. It
collects no personal data from anyone.

## Changes to this policy

Any change to this policy is made in the public repository, so its full history
is visible at <https://github.com/flochrislas/ez-tunein/commits/main/PRIVACY.md>.

## Contact

Questions or concerns: open an issue at
<https://github.com/flochrislas/ez-tunein/issues>.
