#!/usr/bin/env bash
# Builds Minutes.app (release), signs it with an Apple Development identity so macOS keeps the
# privacy permissions across rebuilds, and with --install copies it to /Applications.
#
# Usage: scripts/build-app.sh [--install]
#   SIGN_IDENTITY="Apple Development: …"  override the signing identity
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Minutes.app"
DEST="/Applications/Minutes.app"

swift build -c release --package-path "$ROOT" --product Minutes
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Minutes" "$APP/Contents/MacOS/Minutes"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # regenerate with: swift scripts/make-icon.swift
cp -R "$ROOT/Resources/es.lproj" "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"   # check with: scripts/check-localizations.sh

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [ -z "$IDENTITY" ]; then
  # Ad-hoc signing works, but macOS ties privacy permissions to the exact build, so it asks
  # again after every rebuild. A free Apple Development certificate avoids that.
  echo "warning: no Apple Development signing identity found; signing ad hoc." >&2
  echo "         macOS will ask for the privacy permissions again after each rebuild." >&2
  echo "         Create a free one in Xcode > Settings > Accounts > Manage Certificates." >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  if pgrep -x Minutes >/dev/null; then
    echo "Minutes is running. Quit it from the menu bar first (a recording may be in progress)." >&2
    exit 1
  fi
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"
fi
