#!/usr/bin/env bash
# Build (release) and assemble a self-contained dist/VoiceType.app, ad-hoc signed.
#
# Usage: scripts/package_app.sh [--install]
#   --install   also copy the .app to /Applications
#
# The Metal shader is EMBEDDED in the binary (see scripts/embed_metal_shader.sh),
# so there is nothing extra to bundle — the .app is just the binary + Info.plist.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

APP_NAME="VoiceType"
BUNDLE_ID="com.local.VoiceType"
APP="$ROOT/dist/$APP_NAME.app"
INSTALL=0
if [[ "${1:-}" == "--install" ]]; then
  INSTALL=1
fi

echo "==> Embedding Metal shader"
bash "$ROOT/scripts/embed_metal_shader.sh"

echo "==> Building $APP_NAME (release)"
swift build -c release --package-path "$ROOT"

BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ensuring a stable signing identity"
bash "$ROOT/scripts/create_signing_cert.sh" || true

# Prefer the stable self-signed identity (TCC grants survive rebuilds); fall
# back to ad-hoc if it isn't available.
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "VoiceType Self-Signed"; then
  SIGN_ID="VoiceType Self-Signed"
  security unlock-keychain -p "voicetype-local" "$HOME/Library/Keychains/voicetype-signing.keychain-db" 2>/dev/null || true
  echo "==> Codesigning with '$SIGN_ID' (identifier $BUNDLE_ID) — grants persist across rebuilds"
else
  echo "==> Ad-hoc codesigning (identifier $BUNDLE_ID) — grants will NOT survive rebuilds"
fi
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose "$APP"

if [[ "$INSTALL" -eq 1 ]]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "✓ Installed to $DEST"
  if [[ "$SIGN_ID" != "-" ]]; then
    echo "  Signed with a stable certificate, so Microphone/Accessibility grants"
    echo "  persist across rebuilds — grant once and you're done."
  else
    echo "  Ad-hoc signed: a rebuild changes the signature, so macOS may re-prompt"
    echo "  for Accessibility. Run 'make setup' to create the stable signing cert."
  fi
fi

echo ""
echo "✓ Packaged: $APP"
