# Apple release processes

Planning note (not started) — what it would take to ship **EZ-TuneIn** to Apple
platforms: **macOS** (MacBook / Mac mini), **iPadOS/iOS** (App Store or TestFlight),
and **jailbroken iOS / TrollStore**. Captured 2026-07-01 for a later effort.

Current targets: Windows 11 (primary), Linux (dev), Android, **and now macOS**
(Option 1 below — **implemented** 2026-07-01: an unsigned CI-built `.dmg`). No `ios/`
folder exists yet.

> **Status:** Option 1 (macOS desktop) is **done** — see the `macos` job in
> `.github/workflows/release.yml` and `doc/releasing.md`. It ships an **unsigned**,
> ad-hoc-signed, direct-download `.dmg` for **$0** (no Mac hardware, no Apple Developer
> Program). The remaining Apple work (codesign+notarize, iPad/App Store, TrollStore) is
> still open below.

## The one wall that never goes away

**You need a Mac to build anything for Apple.** Compiling Flutter for macOS *or*
iOS produces ARM64 Mach-O binaries linked against Apple's toolchain — that only
exists on **macOS + Xcode**. There is no cross-compile from Linux/Windows.

Options for the Mac:
- A physical Mac (a **Mac mini** is ideal and cheap), **or**
- A **`macos-latest` GitHub Actions runner** for CI-only builds (occasional local
  Mac access still helps for signing setup / debugging).

Jailbreak/TrollStore removes Apple's *fee and distribution gates* — it does **not**
remove the Mac build requirement.

---

## Option 1 — macOS desktop (MacBook / Mac mini) — ✅ DONE (unsigned CI `.dmg`)

**Implemented 2026-07-01.** What actually shipped: `flutter create --platforms=macos .`
scaffolded `macos/`; the **App Sandbox was dropped** (`macos/Runner/Release.entitlements`)
so the direct-download app has full network + filesystem access; the `macos` job in
`.github/workflows/release.yml` builds on a `macos-latest` runner, **ad-hoc signs**
(`codesign --sign -`, free) so Apple Silicon will run it, packages a universal `.dmg`
with `hdiutil`, and attaches it to the draft Release. **$0, no Mac, no App Store.** The
only thing not done is the optional **codesign + notarize** upgrade (needs the $99
Developer ID) to remove the right-click→Open Gatekeeper step. The original analysis is
kept below for reference.

macOS is a **desktop** target, and the code already treats it as one.

### Already done in the code ✅
- `isDesktop` (`lib/storage_paths.dart`) already includes `Platform.isMacOS`, so all
  desktop paths (window sizing, Documents-folder storage, "reveal in folder", native
  file dialogs) light up automatically.
- Two `Platform.isMacOS` branches already exist in `lib/main.dart` (~2365, ~2950 —
  native dialog / reveal-folder paths).
- `just_audio_media_kit` + `media_kit_libs_audio` support macOS **and bundle their own
  libs** — no `libmpv` install needed (unlike Linux); self-contained like Windows.
- `window_manager`, `share_plus`, `file_picker`, `path_provider`,
  `shared_preferences` all support macOS.
- **No background-audio rewrite needed** — the app just keeps running like on
  Windows/Linux (that problem is iOS-only).

### What's missing
1. Generate the target: `flutter create --platforms=macos .` → creates `macos/`.
   Set bundle ID `io.github.flochrislas.eztunein` and the native window title (the
   macOS equivalent of the Linux `linux/runner/my_application.cc` tweak).
2. **Entitlements** (macOS apps are sandboxed by default):
   - `com.apple.security.network.client` — **required**, or streams won't connect.
   - `com.apple.security.files.user-selected.read-write` — for the "choose an output
     folder" recording feature to write outside the sandbox (`file_picker` handles the
     security-scoped bookmark).
   - Note: macOS is relaxed about **cleartext `http://`** for an outbound client — the
     ATS problem that plagues iOS does **not** bite here.

### Distribution — keeps the GitHub-Releases model ✅
Unlike iOS, macOS allows direct download of a `.dmg`/`.app`. **No App Store required.**
- **Gatekeeper** blocks an unsigned/un-notarized app: *"developer cannot be verified."*
  Users bypass with right-click → **Open** — exactly like the **Windows SmartScreen**
  situation already documented in `doc/windows-signing.md` / README.
- For a warning-free first launch you must **codesign + notarize**, which needs the
  **$99/year Apple Developer Program** (a "Developer ID Application" cert).
- App Store is optional (adds sandbox scrutiny + review) — not worth it here.

### Effort
| Task | Effort |
|---|---|
| `flutter create --platforms=macos`, bundle ID, window title | ~½ day |
| Network + file entitlements | ~½ day |
| Build `.app`/`.dmg` on a Mac, smoke-test | ~½ day |
| macOS CI job on `macos-latest` + `.dmg` packaging | ~1 day |
| Codesign + notarize (needs $99 Apple Developer ID) — **optional** | ~1 day |

- **Unsigned, direct download (right-click→Open, like Windows):** ~1–1.5 days on a Mac,
  **no Apple fee.**
- **Clean signed install:** + $99/year + ~1 day notarization plumbing.

---

## Option 2 — iPad / iPhone via App Store or TestFlight — HARDEST

### Hard blockers (Apple ecosystem, not code)
1. **Mac required** (see top).
2. **Apple Developer Program — $99/year.** Required to distribute to anyone but
   yourself. A *free* Apple ID runs on your own device only, with a provisioning
   profile that **expires every 7 days** (re-sign weekly).
3. **No sideloading — no GitHub-Releases model.** Must go through **TestFlight** (beta,
   up to 10k testers, builds expire after 90 days) or the **App Store** (public,
   subject to review). This is the biggest philosophical shift from Android's APK.

### The one real code change: background audio
- The app already uses **`audio_service`** for the media session (rich notification,
  lock-screen, Bluetooth), and `AudioService.init` is called on **both Android and
  iOS** (`Platform.isAndroid || Platform.isIOS`) — so the Dart side is already wired
  for iOS. `EzAudioHandler` drives both the radio and recordings players behind one
  session (`just_audio_background` was avoided precisely because it allows only one
  `AudioPlayer` app-wide, and `_RecordingsPage` owns a second player).
- What's still **Android-only:** the native Wi-Fi lock (`MainActivity.kt`
  `MethodChannel`) — harmless no-op on iOS (the Dart `WifiLock` guards on
  `Platform.isAndroid`). iOS would instead need the `AVAudioSession` "audio"
  background mode declared in `Info.plist` (`UIBackgroundModes`), which doesn't exist
  yet (no `ios/` folder). Remaining iOS effort is mostly scaffolding + testing, not a
  rewrite (~1–2 days).
- **Background *recording* reliability is a question mark.** The "audio" background mode
  keeps *playback* alive, but the `IcyReader` metadata/recording socket loop on the main
  isolate may still get throttled with the screen off — the iOS version of the Android
  Doze problem, and harder to fully solve. Background *listening* is fine; background
  *recording* is uncertain. Flag up front.

### Mandatory Info.plist / project setup
- `flutter create --platforms=ios .` → creates `ios/`. Set bundle ID.
- **App Transport Security (ATS)** — *this will bite.* iOS blocks cleartext `http://`
  by default, and many Icecast/Shoutcast streams are plain HTTP on odd ports (e.g.
  SwissGroove `relay1.swissgroove.ch:80`). Need an `NSAppTransportSecurity` exception
  (`NSAllowsArbitraryLoads` or per-domain). App Store review scrutinizes blanket
  exceptions — defensible as "generic radio player, user-supplied HTTP streams."
- `UIBackgroundModes` = `audio`.
- Usage-string keys if `share_plus`/`file_picker` touch photos/files.

### What ports for free ✅
- `just_audio` (AVAudioEngine) — full iOS support.
- **ICY metadata** — pure `dart:io HttpClient`; the whole separate-connection metadata
  engine works unchanged.
- **Recording (raw byte dump)** — `getTemporaryDirectory()` + app documents work;
  files land app-private (like Android); `share_plus` is the export path.
- `path_provider`, `shared_preferences`, `file_picker`, `share_plus` — all iOS-capable.
- Desktop-only plugins (`window_manager`, `media_kit`) are inert (guarded by
  `isDesktop`, which excludes iOS).
- **Code audit note:** iOS falls into the `!isDesktop && !isAndroid` bucket, which mostly
  mirrors Android's app-private storage correctly — but audit the ~30 `Platform.isAndroid`
  sites to confirm each should be "Android **or iOS**" vs. genuinely Android-only (the
  foreground-service ones stay Android-only).

### Effort
| Task | Effort |
|---|---|
| Apple Developer enrolment + certs/profiles | ½ day + $99/yr |
| `ios/` project, bundle ID, ATS, Info.plist | ½ day |
| Audit `Platform.isAndroid` sites for iOS inclusion | ½ day |
| Background audio via `audio_service` (2 players) | **2–4 days** (the real work) |
| iOS CI job on `macos-latest` + signing in CI | 1–2 days |
| TestFlight / App Store listing + review round-trips | ongoing |

- **Just run on your own iPad:** Mac + free Apple ID + `ios/` + ATS exception → ~1 day,
  no background audio, re-sign weekly.
- **Actual release:** the $99 program + the `audio_service` rewrite + committing to the
  TestFlight/App Store model.

---

## Option 3 — Jailbroken iOS / TrollStore — niche

Attacks the **signing/distribution** wall, not the build wall.

### What it removes ✅
- **No $99 program.** Jailbroken devices run `AppSync Unified` (`ldid` fake-signing),
  disabling Apple's signature enforcement; self-sign / ad-hoc sign.
- **No App Store/TestFlight, no review** — direct package distribution (GitHub-Releases
  style again).
- **No 7-day re-signing** — installs are permanent.
- **Apple restrictions vanish** — ATS cleartext HTTP, sandbox entitlements, background
  limits all moot. Can grant full filesystem access (so "record to any folder" is
  trivial).

### What it does NOT remove ❌
- **Still need a Mac to build** the iOS binary (see top).
- **Still need the full iOS port** (`ios/` scaffold, bundle ID, `UIBackgroundModes`).
  Jailbreak *relaxes* the rules but doesn't write the `audio_service` background code —
  skip it and background playback still won't work well.

### The three routes
1. **TrollStore `.ipa` — the modern, practical one.** Exploits a CoreTrust bug to
   *permanently* install arbitrary IPAs with **no signing and no full jailbreak**
   (iOS 14–16.x, 17.0 on some hardware). Build an unsigned/ad-hoc `.ipa` on a Mac, ship
   it, users install via TrollStore. No fee, no revocation, no re-signing. **If pursuing
   iOS off-store at all, this is the route.**
2. **`.deb` for Cydia / Sileo / Zebra (classic jailbreak).** Package the `.app` into a
   Debian archive (`control` file, install to `/Applications`, post-install `respring`).
   Host a repo or hand out the `.deb`. Requires a genuinely jailbroken device + AppSync.
   Smallest audience.
3. **AltStore / Sideloadly (no jailbreak).** Sideload the `.ipa` with a free Apple ID —
   but brings back the **7-day expiry** + 3-app limit. Strictly worse than TrollStore
   where available.

### Reality check ⚠️
- **Tiny, shrinking audience.** Jailbreaks lag iOS badly; most modern devices aren't
  jailbreakable. TrollStore widened it, but Apple patched the CoreTrust bug on recent
  iOS — a fixed, aging device pool.
- Same build/CI cost as a proper iPad release (minus the $99 and review) for far fewer
  users.
- GPL-3.0 raises no issue distributing your own app this way.

---

## Summary / recommended order

| Path | Mac? | Apple fee | Audience | Effort | Keeps direct-download? |
|---|---|---|---|---|---|
| **macOS desktop** | yes | $0 (or $99 to notarize) | all Macs | **~1 day** | ✅ yes |
| **TrollStore `.ipa`** | yes | $0 | jailbroken/TrollStore iOS | iOS port + ~½ day pkg | ✅ yes |
| **`.deb` (Cydia/Sileo)** | yes | $0 | full-jailbreak only | iOS port + ~1 day | ✅ yes |
| **App Store iPad** | yes | $99/yr | all iPads | iOS port + review + `audio_service` (~week+) | ❌ store only |

**Recommended:** do **macOS desktop first** — nearly free, code's already there, real
audience, keeps the GitHub-Releases model. For iOS on your *own* iPad, **TrollStore** is
the least-friction route. Both need one Mac to build on.

### Cheap prep possible from Linux now (safe, analyze-clean, no Mac needed)
- `flutter create --platforms=macos .` to scaffold `macos/` + set bundle ID / window
  title / entitlements — leaving only `flutter build macos` for a later Mac.
- (For iOS) audit the ~30 `Platform.isAndroid` sites and mark which become
  "Android or iOS".
