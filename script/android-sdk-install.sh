#!/usr/bin/env bash
#
# One-shot Android SDK setup for this Flutter project (Linux, no Android Studio).
#
# Installs the Android command-line tools + the SDK packages Flutter/Gradle
# need, accepts the SDK licenses, and points Flutter at both the SDK and a
# modern JDK (the system default here is Java 8, which Gradle 9 / AGP 9 reject).
#
# After this, plug in a phone with USB debugging on and run:
#   ~/flutter/bin/flutter devices      # confirm the phone shows up
#   ~/flutter/bin/flutter run          # build + install + run on the phone
#
# Usage:
#   bash script/android-sdk-install.sh
#
# Re-runnable: skips the download if the tools are already laid out.

set -euo pipefail

# --- Config (override via env if needed) -----------------------------------
SDK_DIR="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
FLUTTER="$FLUTTER_DIR/bin/flutter"

# Versioned cmdline-tools zip (filename changes over time; current as of 2026-06).
CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-14742923_latest.zip"

# SDK packages. android-36 / build-tools 36 match the AGP 9 template this
# project uses. flutter doctor at the end will flag a mismatch if there is one.
PLATFORM="platforms;android-36"
BUILD_TOOLS="build-tools;36.0.0"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Find a JDK 17+ for sdkmanager and Gradle ---------------------------
# The system `java` here is 8 — too old (and JAVA_HOME may point at it). We only
# accept a JDK whose major version is >= 17.

# Echo the major version of the JDK at $1 (e.g. "8", "17", "25"), or nothing.
jdk_major() {
  local v
  v="$("$1/bin/java" -version 2>&1 | head -1 | grep -oE '"[0-9._]+"' | tr -d '"')" || return
  case "$v" in
    1.*) echo "${v#1.}" | cut -d. -f1 ;;   # "1.8.0_471" -> 8
    *)   echo "$v"      | cut -d. -f1 ;;   # "25" / "21.0.2" -> 25 / 21
  esac
}

pick_jdk() {
  # An explicitly-set JAVA_HOME, but only if it is new enough.
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    [ "$(jdk_major "$JAVA_HOME")" -ge 17 ] 2>/dev/null && { echo "$JAVA_HOME"; return; }
  fi
  # Known/candidate JDKs, newest first.
  local c
  for c in /usr/lib/jvm/jdk-25 /usr/lib/jvm/jdk-21 /usr/lib/jvm/jdk-17 \
           $(ls -d /usr/lib/jvm/jdk-* 2>/dev/null | sort -Vr); do
    [ -x "$c/bin/java" ] || continue
    [ "$(jdk_major "$c")" -ge 17 ] 2>/dev/null && { echo "$c"; return; }
  done
}
JDK="$(pick_jdk)"
[ -n "$JDK" ] && [ -x "$JDK/bin/java" ] || fail "No JDK 17+ found. Install one (e.g. sudo apt install openjdk-21-jdk) and re-run."
export JAVA_HOME="$JDK"
export PATH="$JAVA_HOME/bin:$PATH"
info "Using JDK at: $JAVA_HOME ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1))"

# --- 2. Download + lay out the command-line tools --------------------------
# Required layout is $SDK_DIR/cmdline-tools/latest/bin/...
SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
if [ -x "$SDKMANAGER" ]; then
  info "cmdline-tools already present at $SDK_DIR/cmdline-tools/latest — skipping download."
else
  info "Downloading Android command-line tools…"
  mkdir -p "$SDK_DIR/cmdline-tools"
  tmp="$(mktemp -d)"
  curl -fL -o "$tmp/cmdline-tools.zip" "$CMDLINE_URL"
  info "Unzipping…"
  unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"   # extracts a top-level "cmdline-tools" dir
  rm -rf "$SDK_DIR/cmdline-tools/latest"
  mv "$tmp/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  rm -rf "$tmp"
  [ -x "$SDKMANAGER" ] || fail "sdkmanager not found after extract — layout unexpected."
fi

# --- 3. Install SDK packages -----------------------------------------------
# NB: disable pipefail around `yes | sdkmanager` — when sdkmanager exits, `yes`
# dies from a broken pipe (141); with pipefail+`set -e` that would abort us.
info "Installing: platform-tools, $PLATFORM, $BUILD_TOOLS …"
set +o pipefail
yes | "$SDKMANAGER" --sdk_root="$SDK_DIR" \
  "platform-tools" "$PLATFORM" "$BUILD_TOOLS"

# --- 4. Accept all licenses ------------------------------------------------
info "Accepting SDK licenses…"
yes | "$SDKMANAGER" --sdk_root="$SDK_DIR" --licenses >/dev/null
set -o pipefail

# --- 5. Point Flutter at the SDK and the JDK -------------------------------
# Without --jdk-dir, Flutter would use the PATH java (8) for Gradle and fail.
info "Configuring Flutter (android-sdk + jdk-dir)…"
"$FLUTTER" config --android-sdk "$SDK_DIR"
"$FLUTTER" config --jdk-dir "$JAVA_HOME"

# --- 6. Persist ANDROID_HOME for future shells (idempotent) ----------------
if ! grep -qF "ANDROID_HOME=$SDK_DIR" "$HOME/.bashrc" 2>/dev/null; then
  info "Adding ANDROID_HOME + platform-tools to ~/.bashrc…"
  {
    echo ""
    echo "# Android SDK"
    echo "export ANDROID_HOME=\"$SDK_DIR\""
    echo "export PATH=\"\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin:\$PATH\""
  } >> "$HOME/.bashrc"
fi

# --- 7. Verify -------------------------------------------------------------
info "Running flutter doctor…"
"$FLUTTER" doctor || true

cat <<EOF

------------------------------------------------------------------
Android SDK installed at: $SDK_DIR
JDK used for builds:      $JAVA_HOME

The Android toolchain line above should now be [✓]. If it complains
about licenses, re-run:  $SDKMANAGER --licenses

Next — plug in your phone (Settings → Developer options → USB debugging),
then from the project directory:
  ~/flutter/bin/flutter devices     # phone should appear
  ~/flutter/bin/flutter run         # build + run on the phone

(Open a NEW terminal or 'source ~/.bashrc' to get adb on PATH.)
------------------------------------------------------------------
EOF
