# Releasing

How to cut a new **EZ-TuneIn Radio** release. Releases are built and published by
GitHub Actions ([`.github/workflows/release.yml`](../.github/workflows/release.yml))
when you push a `v*` tag — you don't build the artifacts by hand.

Each release attaches four deliverables to a GitHub Release:

| Platform | Asset | Notes |
|---|---|---|
| Android | `ez-tunein-<tag>-android.apk` | signed with the upload key; sideload |
| Linux | `ez-tunein-<tag>-linux-x64.tar.gz` | needs `libmpv` on the user's machine |
| Windows | `ez-tunein-<tag>-windows-x64.zip` | unsigned — SmartScreen warns (see [`windows-signing.md`](./windows-signing.md)) |
| macOS | `ez-tunein-<tag>-macos.dmg` | unsigned/ad-hoc — Gatekeeper warns, right-click → Open (see below) |

The workflow builds each on its own cloud runner (Windows and macOS can't be
cross-compiled from Linux — this is why we automate it), then publishes a **draft**
release for review before anything goes public.

A `verify` job (`flutter analyze` + `flutter test`) runs first; the four platform
build jobs `needs:` it, so a tag whose code fails analyze or tests never produces
artifacts. The same checks run on every push/PR via
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) (CI stays on Linux only —
the macOS build runs at release time to keep per-push CI fast).

### macOS build — unsigned, $0, no Mac needed

The `macos` job runs on a `macos-latest` runner, so **no Mac hardware and no Apple
Developer Program ($99/yr)** are required. It's built **unsigned**; the one non-obvious
step is a free **ad-hoc** signature (`codesign --force --deep --sign -`) applied to the
`.app` before packaging — Apple Silicon hard-refuses a *truly* unsigned binary as
"damaged", and the ad-hoc signature (no certificate, no fee) fixes that. Users still
right-click → **Open** on first launch to clear Gatekeeper's "developer cannot be
verified" warning, exactly like the Windows SmartScreen case.

The `.dmg` is universal (arm64 + x86_64), so one file serves Intel and Apple Silicon —
hence the plain `-macos` suffix (no `-x64`). The `macos/` Xcode project ships
**without the App Sandbox** (`macos/Runner/Release.entitlements`), giving the
direct-download app unrestricted network + filesystem access with no entitlement tuning.
To notarize for a warning-free launch later would need the $99 Developer ID (a
`Developer ID Application` cert + `xcrun notarytool`) — deliberately skipped here.

## One-time setup (already done — for reference / new machines)

1. **Android signing.** Run [`script/android-signing-setup.sh`](../script/android-signing-setup.sh)
   to generate the upload keystore (`~/.keystores/ez_tunein-upload.jks`) and
   `android/key.properties`. **Back up the keystore** — losing it means you can
   never ship an update that installs over an existing release. See
   [`android-build.md`](./android-build.md).

2. **Repository secrets** (Settings → Secrets and variables → Actions), used by
   the workflow to sign the Android build in CI:

   ```bash
   base64 -w0 ~/.keystores/ez_tunein-upload.jks | gh secret set ANDROID_KEYSTORE_BASE64
   gh secret set ANDROID_KEYSTORE_PASSWORD          # paste the signing password
   gh secret set ANDROID_KEY_ALIAS --body upload
   ```

   Confirm with `gh secret list`.

## Cutting a release

1. **Bump the version** in `pubspec.yaml`. Format is `X.Y.Z+B`:
   - `X.Y.Z` is the user-facing version (and must match the tag).
   - `+B` is the Android `versionCode` — **increment it every release**, or
     Android refuses to install the update over the previous one.

   ```yaml
   version: 0.1.1+2
   ```

   Commit it (and push to `main`): `git commit -am "chore: bump to 0.1.1+2"`.

2. **Tag and push** — this triggers the build:

   ```bash
   git tag v0.1.1
   git push origin v0.1.1
   ```

   > The tag must point at a commit that already contains `release.yml` (i.e. push
   > your version-bump commit to `main` first). The tag (`v0.1.1`) and the
   > `pubspec.yaml` version (`0.1.1`) must match.

3. **Watch the run** (~5–10 min; six jobs: `verify`, then `android`, `linux`,
   `windows`, `macos`, then `release`):

   ```bash
   gh run watch $(gh run list --workflow=release.yml -L1 --json databaseId -q '.[0].databaseId')
   ```

4. **Review the draft release.** The `release` job creates a *draft* with the
   four assets and auto-generated notes:

   ```bash
   gh release view v0.1.1 --web
   ```

   Smoke-test the artifacts — especially the **Windows zip** and **macOS dmg**, which
   are never built locally (unzip and run `ez_tunein.exe`; for macOS, mount the `.dmg`,
   drag to Applications, right-click → **Open**). Edit the notes if you like.

5. **Publish:**

   ```bash
   gh release edit v0.1.1 --draft=false --latest
   ```

   (or click **Publish release** in the web UI).

## If a build fails

First runs on changed runners can surface environment issues. Inspect the failing
job and fix `release.yml`:

```bash
gh run view <run-id> --log-failed
```

Then push the workflow fix to `main`. To re-run the same tag, delete and re-push it:

```bash
git push origin :v0.1.1 && git tag -d v0.1.1     # delete remote + local tag
git tag v0.1.1 && git push origin v0.1.1          # re-tag the fixed commit
```

(Also delete the stale draft release if one was created: `gh release delete v0.1.1`.)

## Release notes for users

The auto-generated notes list merged commits. The workflow's release body also
spells out the per-platform install steps and caveats (Linux needs `libmpv`;
Windows shows a SmartScreen warning). Keep those caveats accurate if the runtime
requirements change.

## Possible improvements

- **Windows code signing** (SignPath) in the marked slot of `release.yml` to drop
  the SmartScreen warning — see [`windows-signing.md`](./windows-signing.md).
- **macOS codesign + notarization** (needs the $99 Apple Developer ID) to drop the
  Gatekeeper "developer cannot be verified" warning — see
  [`Apple release processes.md`](./Apple%20release%20processes.md).
- A hand-written `CHANGELOG.md` for richer notes than the auto-generated list.
- A self-contained Linux artifact (AppImage/Flatpak) so users don't need `libmpv`.
