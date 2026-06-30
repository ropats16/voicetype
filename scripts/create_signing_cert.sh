#!/usr/bin/env bash
# Create a stable, self-signed code-signing certificate so macOS permission
# grants (Accessibility, Microphone) SURVIVE REBUILDS.
#
# Why: ad-hoc signing (`codesign -s -`) produces a new CDHash on every build, and
# TCC pins Accessibility to the CDHash — so each `make install` silently revokes
# the grant. A self-signed certificate gives a stable signing identity, so the
# grant keys off the (unchanging) certificate and persists across rebuilds.
#
# The cert lives in a dedicated, local-only keychain (so we never need your login
# password). It is NOT a security secret — it only signs this local dev build.
# To undo everything later: `security delete-keychain "$KEYCHAIN"`.
#
# Idempotent: does nothing if the identity already exists.
set -euo pipefail

CERT_CN="VoiceType Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/voicetype-signing.keychain-db"
KEYCHAIN_PASS="voicetype-local"   # local signing keychain only; not a secret
# Use macOS's system LibreSSL: Homebrew's OpenSSL 3 writes PKCS12 with a MAC the
# macOS `security` importer can't verify ("MAC verification failed").
OPENSSL="/usr/bin/openssl"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
  echo "✓ Signing identity '$CERT_CN' already present"
  exit 0
fi

echo "Creating self-signed code-signing certificate '$CERT_CN'…"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = VoiceType Self-Signed
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CERT_CN" -passout pass:p12pass 2>/dev/null

# Dedicated keychain (created with a known password so we can manage it without
# the user's login password).
if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"                 # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"

# Add to the user keychain search list, preserving the existing entries.
if ! security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g' | grep -qx "$KEYCHAIN"; then
  EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

security import "$TMP/id.p12" -k "$KEYCHAIN" -P p12pass -A -T /usr/bin/codesign
# Let codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -p codesigning | grep -q "$CERT_CN"; then
  echo "✓ Created signing identity '$CERT_CN' (in voicetype-signing.keychain)"
else
  echo "warning: identity not found after import; packaging will fall back to ad-hoc." >&2
  exit 1
fi
