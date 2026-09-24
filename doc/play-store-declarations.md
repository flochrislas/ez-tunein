# Google Play: policy declarations for EZ-TuneIn

What Play Console asks for beyond the build itself, and the answers prepared for
this app. Everything here is about **policy**, not code: the app already
declares the right permissions (see `android/app/src/main/AndroidManifest.xml`).

## 1. Foreground service permission declaration

**Why it's required.** Since target SDK 34, any app that declares a
`FOREGROUND_SERVICE_<TYPE>` permission must justify each type in Play Console.
EZ-TuneIn declares exactly one: `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, used by
`audio_service`'s `AudioService` (`android:foregroundServiceType="mediaPlayback"`).
Google reviews the declaration and rejects the release if the type doesn't match
the visible behaviour or the video doesn't show it.

**Where.** Play Console → your app → **App content** (left menu, under
*Policy*) → **Foreground service permissions** → *Start declaration*. It has to
be completed before the first release that targets SDK 34+ can be rolled out;
Play also re-asks when a new type is added.

**What to enter.**

| Field | Answer |
|---|---|
| Foreground service type | **Media playback** (`mediaPlayback`) |
| Does your app use it? | Yes |
| Feature description (user-facing) | Copy the text below. |
| Video demonstration | A short screen recording (link to YouTube/Drive, publicly viewable). See the shot list below. |

**Justification text** (paste, ≤ 500 characters is safe):

> EZ-TuneIn is an internet radio player. When the user starts a station, a
> media-playback foreground service keeps the live audio stream playing after
> the screen turns off or the user switches apps, and shows a media notification
> with play/pause/stop and lock-screen controls. The same service keeps the
> optional stream recording running so a song the user chose to record is not
> cut off when the screen locks. The service stops when the user presses Stop or
> swipes the notification away.

**Video shot list** (30–60 s, one take, phone screen recording; no audio
needed but keep it on if you can):

1. Open the app, tap a station. Audio starts, the now-playing title appears.
2. Swipe down the shade: show the media notification with its controls.
3. Press the power button, wake the screen: show the lock-screen media controls
   and that playback is still running (title still updating / progress).
4. Optional but helpful: tap Record before step 3, then show the recording
   still active after the lock (the red neon border on the now-playing box).
5. Tap Stop in the notification: it disappears and playback ends.

**Things that get declarations rejected** (avoid):

- Declaring a type the app doesn't visibly use. We only declare one; **don't**
  add `FOREGROUND_SERVICE_DATA_SYNC` or others "just in case".
- A video that doesn't show the notification or the lock screen.
- A justification that describes something the app does *not* do (e.g. "playing
  local files in the background" is true only for the Recordings view; the text
  above covers the primary radio case, which is what reviewers check).

## 2. Privacy policy

**Why it's required.** Play requires every app to link a privacy policy, both
on the store listing and **inside the app**, regardless of what data it
handles.

**What we have.**

- The policy is [`PRIVACY.md`](../PRIVACY.md) in the repo root; the hosted URL
  is <https://github.com/flochrislas/ez-tunein/blob/main/PRIVACY.md>. GitHub
  renders Markdown, is always up, and the commit history doubles as the
  change log Play expects a policy to have.
- In-app: Settings → bottom "about" band → **Privacy policy** button opens the
  same URL (`lib/settings/settings_page.dart`, `_privacyUrl`).

**Where.** Play Console → **App content** → **Privacy policy** → paste the URL.
It must be a plain page (no PDF, no login), which the GitHub blob page is.

**Keep it true.** The policy says the only outbound traffic is the stream
connection, Radio Browser searches, and user-tapped links. If a feature is ever
added that phones home (update check, analytics, crash reporting), update
`PRIVACY.md` *in the same change*, and revisit the Data safety form (below).

## 3. Still to do (not covered here)

- **Data safety form** (App content → Data safety). Current honest answers:
  no data collected, no data shared. The Radio Browser search keyword is sent
  off-device but is not tied to the user and is not stored by the app; declaring
  "no collection" is the standard interpretation for an ephemeral request, but
  read the form's definitions when filling it in.
- **App bundle.** Play accepts `.aab` only. The release workflow now builds
  one next to the APK (`ez-tunein-<tag>-android.aab`, signed with the same
  upload key and fingerprint-checked in CI); download it from the draft release
  and upload it in Play Console. Enrol in **Play App Signing** on the first
  upload: Google then re-signs with its own app-signing key and our keystore
  becomes the *upload* key.
- **Content rating**, **target audience** (18+ or "not designed for children" —
  the app is general audience, pick the adult-only option to stay out of the
  Families policy), **ads declaration** (none), **News/Government** flags (no).
