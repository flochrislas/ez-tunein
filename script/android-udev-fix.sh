#!/usr/bin/env bash
#
# Fix "adb: insufficient permissions for device / missing udev rules?" on Linux.
#
# By default a plugged-in Android phone's USB node is owned by root, so adb can
# see its serial but can't open it. This installs a udev rule granting your user
# access (via the uaccess tag + plugdev group), keyed on the phone's USB vendor
# ID, plus Ubuntu's maintained Android rules as a backstop.
#
# Usage (phone plugged in, USB debugging on):
#   sudo bash script/android-udev-fix.sh
#
# Re-runnable. After it finishes, UNPLUG and REPLUG the phone, then approve the
# "Allow USB debugging?" prompt on the device.

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo: sudo bash $0" >&2; exit 1; }

RULES=/etc/udev/rules.d/51-android.rules
# adb lives in the SDK we installed; SUDO_USER is the real (non-root) user.
REAL_USER="${SUDO_USER:-$USER}"
ADB="$(eval echo "~$REAL_USER")/Android/Sdk/platform-tools/adb"
[ -x "$ADB" ] || ADB="$(command -v adb || true)"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# --- 1. Ubuntu's maintained Android udev rules (broad vendor coverage) ------
if ! dpkg -s android-sdk-platform-tools-common >/dev/null 2>&1; then
  info "Installing android-sdk-platform-tools-common (maintained udev rules)…"
  apt-get update && apt-get install -y android-sdk-platform-tools-common || \
    info "apt install failed/unavailable — relying on the auto-detected rule below."
fi

# --- 2. Auto-detect THIS phone's USB vendor id and add a precise rule -------
# Read the adb serial (shown even when access is denied), then find the matching
# USB device in sysfs and pull its idVendor.
SERIAL=""
if [ -n "${ADB:-}" ] && [ -x "$ADB" ]; then
  SERIAL="$("$ADB" devices 2>/dev/null | awk 'NR>1 && $1 != "" {print $1; exit}')"
fi

VENDOR=""
if [ -n "$SERIAL" ]; then
  info "Phone serial: $SERIAL — locating its USB vendor id…"
  for d in /sys/bus/usb/devices/*; do
    if [ -f "$d/serial" ] && [ "$(cat "$d/serial" 2>/dev/null)" = "$SERIAL" ]; then
      VENDOR="$(cat "$d/idVendor" 2>/dev/null)"
      break
    fi
  done
fi

if [ -n "$VENDOR" ]; then
  info "Detected USB vendor id: $VENDOR — writing rule to $RULES"
  RULE="SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$VENDOR\", MODE=\"0660\", GROUP=\"plugdev\", TAG+=\"uaccess\""
  touch "$RULES"
  grep -qF "ATTR{idVendor}==\"$VENDOR\"" "$RULES" 2>/dev/null || {
    echo "# EZ-TuneIn: grant access to Android phone (auto-detected $(date -u +%F))" >> "$RULES"
    echo "$RULE" >> "$RULES"
  }
else
  info "Could not auto-detect the vendor id (serial=$SERIAL). The maintained"
  info "package rules from step 1 should still cover common vendors."
fi

# --- 3. Make sure the user is in plugdev -----------------------------------
if ! id -nG "$REAL_USER" | grep -qw plugdev; then
  info "Adding $REAL_USER to the plugdev group…"
  usermod -aG plugdev "$REAL_USER"
  info "NOTE: group change needs a fresh login to fully apply."
fi

# --- 4. Reload udev + restart adb ------------------------------------------
info "Reloading udev rules…"
udevadm control --reload-rules
udevadm trigger

if [ -n "${ADB:-}" ] && [ -x "$ADB" ]; then
  info "Restarting adb server…"
  sudo -u "$REAL_USER" "$ADB" kill-server 2>/dev/null || true
  sudo -u "$REAL_USER" "$ADB" start-server 2>/dev/null || true
fi

cat <<EOF

------------------------------------------------------------------
Done. Now:
  1. UNPLUG and REPLUG the phone.
  2. On the phone, approve "Allow USB debugging?" (tick "always allow").
  3. Back in the project dir, check it's authorized:
       ~/flutter/bin/flutter devices

The phone should now show a real model name (not "unsupported").
------------------------------------------------------------------
EOF
