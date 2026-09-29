# To-do next for the Play Store

Everything the repo could prepare is done (privacy policy, Play declaration
answers, signed `.aab` in the release workflow). What's left is Console work and
one test cycle. In order:

## 1. Developer account

- [ ] Create a Google Play Developer account (one-time US$25) at
      <https://play.google.com/console>. Register as an **individual** unless
      you have a legal entity; identity verification (ID + address) takes a
      few days and blocks publishing until done.
- [ ] Note: **personal accounts created after Nov 2023 must run a closed test
      with at least 12 testers opted in for 14 continuous days** before they
      can apply for production access. Plan for it (step 6).

## 2. Signing setup

- [ ] Create the app in the Console (name **EZ-TuneIn Radio**, default
      language, "App", free).
- [ ] Under **Test and release → Setup → App signing**, enrol in **Play App
      Signing** with the *Google-generated* key option. Our keystore becomes the
      *upload key*; Google re-signs what users install. Nothing to change in
      the repo.

## 3. Store listing (Grow → Store presence → Main store listing)

- [ ] Short description (≤ 80 chars) and full description (≤ 4000). Reuse the
      README feature list; mention "records songs from the stream" plainly.
- [ ] App icon 512×512 PNG: export from `assets/icon/icon.png`.
- [ ] Feature graphic 1024×500 (required). Make one from the icon + name.
- [ ] Phone screenshots, at least 2 (recommended 4–8), 16:9 or 9:16, ≥ 320 px.
      Take them on the phone; the desktop shots in `doc/screenshots/` are the
      wrong aspect ratio.
- [ ] Category **Music & Audio**, contact email, and the privacy policy URL:
      `https://github.com/flochrislas/ez-tunein/blob/main/PRIVACY.md`.

## 4. App content forms (Policy → App content)

Answers are all in [`play-store-declarations.md`](./play-store-declarations.md).

- [ ] **Privacy policy**: paste the URL above.
- [ ] **Ads**: no ads.
- [ ] **App access**: all functionality available without login.
- [ ] **Content rating**: fill the IARC questionnaire (utility/music app, no
      user-generated content shared with others, no violence, etc.).
- [ ] **Target audience**: 18+ (or 13+ minimum) so the app stays outside the
      Families policy. Answer "not designed for children".
- [ ] **News app**: no. **COVID / Health**: no. **Government**: no.
- [ ] **Data safety**: follow the table in section 3 of the declarations doc
      (In-app search history, ephemeral, optional, not shared).
- [ ] **Foreground service permissions**: type *Media playback*, paste the
      justification from section 1, link the demo video (next step).

## 5. Demo video for the foreground-service declaration

- [ ] Record 30–60 s on the phone following the shot list in section 1 of the
      declarations doc: start a station → notification → lock screen with
      controls, playback continues → Stop.
- [ ] Upload as an **unlisted** YouTube video (or a public Drive link) and paste
      the link in the declaration.

## 6. First upload and the closed test

- [ ] Bump the version in `pubspec.yaml` (each Play upload needs a higher
      `versionCode`, the `+N` part), tag `vX.Y.Z`, push. Wait for the release
      workflow; download `ez-tunein-vX.Y.Z-android.aab` from the draft release.
- [ ] **Test and release → Testing → Closed testing**: create a track, upload
      the `.aab`, add a tester list (Google account emails, or a Google Group),
      roll out. Share the opt-in link with the testers.
- [ ] Get **12 testers opted in** and keep the test running **14 days**. Ask
      them to try screen-off playback and a recording — that's also what the
      pre-launch report checks.
- [ ] Read the **pre-launch report** (Testing → Pre-launch report). Expect a
      warning about `usesCleartextTraffic`; it's a warning, not a blocker (many
      radio relays are plain HTTP, see the declarations doc).

## 7. Production

- [ ] After 14 days, **apply for production access** (the Console prompts for
      it; a short questionnaire about the test results).
- [ ] Once granted: Production → create release → upload the same or a newer
      `.aab` → review the release summary → **Start rollout** (a staged 20%
      rollout first is fine).
- [ ] Review usually takes hours to a few days for a new app. Fix anything
      flagged, bump the version, re-upload.

## 8. After launch (keep true)

- [ ] Any feature that sends data off-device: update `PRIVACY.md`, the Data
      safety form and the declarations doc in the same change.
- [ ] Each release: upload the new `.aab` to production (the APK on GitHub stays
      for sideloaders). Play requires the target SDK to stay within one year of
      the latest Android; Flutter's default (currently 36) handles this.
- [ ] Keep the upload keystore backed up. Losing it is recoverable only through
      Google's upload-key reset process, which takes days.
