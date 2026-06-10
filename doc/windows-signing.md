# Windows Code Signing (notes & options)

Whether to sign the Windows `.exe`, and whether that removes the
**Microsoft Defender SmartScreen** warning ("Windows protected your PC — Windows
Defender SmartScreen prevented an unrecognized app from starting").

**Status:** not done. The Windows release artifact currently ships **unsigned**.
This note records the decision and the options for later.

## What signing does — and doesn't

Signing the executable with a **publicly-trusted** code-signing certificate:

- ✅ Removes the **"Unknown Publisher"** label (the app shows the real publisher).
- ⚠️ Helps with the **SmartScreen** warning, but only by *building reputation over
  time* — it does **not** suppress the warning on day one.

Two things that surprise people:

1. **A self-signed certificate does nothing here.** Unlike the Android keystore
   (which we self-manage, for free — see [`android-build.md`](./android-build.md)),
   SmartScreen only trusts certificates from a recognised CA. A self-signed cert
   removes neither warning for end users.
2. **EV certificates no longer give instant SmartScreen bypass.** Microsoft
   removed that behaviour in **March 2024**. EV and OV certificates now build
   reputation the same way, so paying the EV premium *just* to skip SmartScreen
   is no longer worth it.

## How SmartScreen reputation works

SmartScreen weighs two signals:

- **Publisher reputation** — is it signed, by a known/trusted certificate?
- **File-hash reputation** — has *this exact file* been downloaded and run by many
  users without trouble?

A freshly-signed binary from a new publisher can still warn until it accrues
downloads. The payoff of signing is that reputation attaches to the **certificate**,
so signing **every** release with the **same** cert accumulates trust across
versions. Unsigned files start from zero every release.

## The practical catch

Since **June 2023**, CA-issued code-signing private keys must live on a hardware
token or HSM (CA/Browser Forum rule). So you either buy a token or use a
cloud/managed signing service. For a GPL open-source project the realistic options:

| Option | Cost | Notes |
|---|---|---|
| **SignPath Foundation** | **Free** for qualifying OSS | OV-level, HSM-backed (they hold the key), integrates with GitHub Actions. Requires an attribution line. Works regardless of country. **Best fit here.** |
| **Azure Artifact Signing** (ex–Trusted Signing) | Cheap, CI-native, no token | As of Feb 2026, **individual** developers limited to US/Canada — likely ineligible for this project. |
| **Certum Open Source** / **OSSign** | Low-cost / free for OSS | Trusted by Windows; may ship a hardware token. |
| **Microsoft Store (MSIX)** | Store fee | Store-distributed apps are signed by Microsoft and never hit SmartScreen — but it's a separate packaging + submission path. |

None of these (except the Store route) give *instant* trust — reputation still
builds over downloads.

## Recommendation

Don't let signing block a release. Shipping the Windows zip **unsigned** with a
short note to users ("Windows may warn — click **More info → Run anyway**") is
normal for small OSS desktop apps.

When the warning is worth removing, **SignPath Foundation** is the clean path:
apply once, then have the release CI (GitHub Actions) sign the `.exe` as a build
step (via `signtool` or SignPath's connector) — the same workflow that builds the
artifacts. Use a **consistent publisher identity** and **timestamp** every signed
file so reputation carries across releases.

## Sources

- [SmartScreen reputation for Windows app developers — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)
- [Code signing options for Windows app developers — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)
- [EV-signed application showing SmartScreen warnings — DigiCert](https://knowledge.digicert.com/alerts/ev-signed-application-showing-microsoft-defender-smartscreen-warnings)
- [SignPath Foundation — free code signing for OSS](https://signpath.org/)
- [Certum Open Source Code Signing](https://certum.store/open-source-code-signing-code.html)
