#!/usr/bin/env bash
# Builds Speechy and assembles a runnable, ad-hoc-signed Speechy.app bundle.
# No Xcode required — uses the SwiftPM toolchain from Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/Speechy.app"
CONFIG="${1:-release}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Speechy"
if [[ ! -f "$BIN" ]]; then
  echo "✗ Build product not found at $BIN" >&2
  exit 1
fi

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Speechy"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Prefer a stable self-signed identity ("Speechy Self-Signed") so the
# Accessibility / Microphone grants persist across rebuilds. Fall back to
# ad-hoc (which changes identity every build → permissions reset) if it's
# missing. Create the identity with scripts/make_signing_identity.sh.
SIGN_ID="Speechy Self-Signed"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "▸ Signing with stable identity ($SIGN_ID)…"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  echo "▸ Ad-hoc signing (no stable identity found)…"
  codesign --force --deep --sign - "$APP"
fi

echo "✓ Built $APP"
echo "  Run it:   open \"$APP\""
echo "  Install:  cp -R \"$APP\" /Applications/ && open /Applications/Speechy.app"
