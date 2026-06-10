#!/usr/bin/env bash
#
# One-shot Android release-signing setup.
#
# Generates an upload keystore (outside the repo) and writes android/key.properties
# so `flutter build apk --release` produces a properly-signed APK instead of one
# signed with the insecure debug key. The build wiring that reads key.properties
# already lives in android/app/build.gradle.kts (with a fallback to debug signing
# when no keystore is present, so the project still builds without it).
#
# Usage:
#   bash script/android-signing-setup.sh
#
# SECRETS: the keystore and android/key.properties contain your signing key and
# passwords. Both are git-ignored — NEVER commit them, and keep a safe backup of
# the keystore (lose it and you can never ship an update that installs over an
# existing release).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEY_PROPS="$REPO/android/key.properties"

# --- Config (override via env) ---------------------------------------------
KEYSTORE="${KEYSTORE:-$HOME/.keystores/ez_tunein-upload.jks}"
ALIAS="${ALIAS:-upload}"
VALIDITY_DAYS="${VALIDITY_DAYS:-10000}"   # ~27 years
DNAME="${DNAME:-CN=EZ-TuneIn, O=flochrislas, C=JP}"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Find keytool (any JDK works; prefer a modern one) ---------------------
KEYTOOL=""
for c in "${JAVA_HOME:-}/bin/keytool" /usr/lib/jvm/jdk-25/bin/keytool "$(command -v keytool 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { KEYTOOL="$c"; break; }
done
[ -n "$KEYTOOL" ] || fail "keytool not found. Install a JDK (the project uses /usr/lib/jvm/jdk-25)."
info "Using keytool: $KEYTOOL"

# --- Guard against clobbering an existing keystore -------------------------
if [ -f "$KEYSTORE" ]; then
  fail "Keystore already exists at $KEYSTORE — refusing to overwrite.
       Delete it (and re-run) only if you are SURE no release was signed with it,
       or set KEYSTORE=/some/other/path to create a different one."
fi

# --- Collect the passwords (hidden input) ----------------------------------
echo "A single password protects both the keystore and the key (the common case)."
read -r -s -p "Choose a signing password: " PASS; echo
[ -n "$PASS" ] || fail "Password must not be empty."
read -r -s -p "Confirm password: " PASS2; echo
[ "$PASS" = "$PASS2" ] || fail "Passwords do not match."

# --- Generate the keystore -------------------------------------------------
info "Generating keystore at $KEYSTORE (alias: $ALIAS, validity: $VALIDITY_DAYS days)…"
mkdir -p "$(dirname "$KEYSTORE")"
"$KEYTOOL" -genkeypair -v \
  -keystore "$KEYSTORE" \
  -storepass "$PASS" -keypass "$PASS" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity "$VALIDITY_DAYS" \
  -dname "$DNAME"
chmod 600 "$KEYSTORE"

# --- Write android/key.properties ------------------------------------------
info "Writing $KEY_PROPS (git-ignored)…"
cat > "$KEY_PROPS" <<EOF
storePassword=$PASS
keyPassword=$PASS
keyAlias=$ALIAS
storeFile=$KEYSTORE
EOF
chmod 600 "$KEY_PROPS"

# --- Sanity check: confirm both are git-ignored ----------------------------
if git -C "$REPO" check-ignore -q android/key.properties && \
   { case "$KEYSTORE" in "$REPO"/*) git -C "$REPO" check-ignore -q "${KEYSTORE#"$REPO"/}";; *) true;; esac; }; then
  info "Confirmed: key.properties (and any in-repo keystore) are git-ignored."
else
  printf '\033[1;33mWARNING:\033[0m double-check that key.properties / the keystore are git-ignored before committing.\n'
fi

cat <<EOF

------------------------------------------------------------------
Android release signing is set up.

  Keystore:        $KEYSTORE
  Properties:      $KEY_PROPS  (storeFile points at the keystore)

Verify a signed release build:
  ~/flutter/bin/flutter build apk --release
  # then check it is NOT debug-signed:
  ~/Android/Sdk/build-tools/36.0.0/apksigner verify --print-certs \\
    build/app/outputs/flutter-apk/app-release.apk

BACK UP the keystore somewhere safe (password manager / encrypted backup).
If you lose it you cannot ship updates that install over this release.

For CI (GitHub Actions) later, you'll add these as repository secrets:
  - the keystore, base64-encoded:   base64 -w0 "$KEYSTORE"
  - the password, alias, and storeFile name
------------------------------------------------------------------
EOF
