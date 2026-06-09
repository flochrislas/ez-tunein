#!/usr/bin/env bash
#
# One-shot Flutter install for Linux (Debian/Ubuntu).
#
# Installs build prerequisites + the libmpv runtime this project needs, clones
# the Flutter stable SDK, puts it on your PATH, and runs `flutter doctor`.
#
# Usage:
#   bash flutter-install.sh
#
# Re-runnable: skips anything already present. Uses sudo only for apt.

set -euo pipefail

FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
FLUTTER_CHANNEL="${FLUTTER_CHANNEL:-stable}"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# 1. System packages: git/curl/unzip for the SDK, the Linux-desktop toolchain
#    (clang/cmake/ninja/gtk), and libmpv for this app's audio backend.
info "Installing system packages (sudo apt)…"
sudo apt-get update
sudo apt-get install -y \
  git curl unzip xz-utils zip \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev \
  libmpv-dev mpv

# 2. Flutter SDK (git clone — version-agnostic, no snap required).
if [ -d "$FLUTTER_DIR/.git" ]; then
  info "Flutter already cloned at $FLUTTER_DIR — pulling latest $FLUTTER_CHANNEL…"
  git -C "$FLUTTER_DIR" pull --ff-only || true
else
  info "Cloning Flutter ($FLUTTER_CHANNEL) into $FLUTTER_DIR…"
  git clone --depth 1 -b "$FLUTTER_CHANNEL" \
    https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

# 3. Add Flutter to PATH permanently (idempotent) for future shells.
LINE="export PATH=\"$FLUTTER_DIR/bin:\$PATH\""
if ! grep -qF "$FLUTTER_DIR/bin" "$HOME/.bashrc" 2>/dev/null; then
  info "Adding Flutter to PATH in ~/.bashrc…"
  {
    echo ""
    echo "# Flutter SDK"
    echo "$LINE"
  } >> "$HOME/.bashrc"
fi

# 4. Download the engine artifacts and report status.
info "Pre-caching Flutter engine artifacts…"
flutter precache

info "Running flutter doctor…"
flutter doctor || true

cat <<EOF

------------------------------------------------------------------
Flutter installed at: $FLUTTER_DIR
This shell already has it on PATH. For NEW terminals, either open a
fresh one or run:  source ~/.bashrc

Next, from the project directory:
  flutter create --platforms=linux,windows,android .
  flutter pub get
  flutter run -d linux
------------------------------------------------------------------
EOF
