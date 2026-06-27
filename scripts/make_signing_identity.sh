#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity named "Speechy Self-Signed"
# and imports it into the login keychain. Signing the app with a *consistent*
# identity (instead of ad-hoc, which changes every build) lets macOS keep the
# Accessibility / Microphone grants across rebuilds — no more re-granting.
#
# Run once. build_app.sh picks the identity up automatically.
set -euo pipefail

NAME="Speechy Self-Signed"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✓ '$NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Speechy Self-Signed
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "▸ Generating key + certificate…"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf" 2>/dev/null

echo "▸ Packaging .p12 with legacy algorithms (macOS-importable)…"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:speechy -name "$NAME" \
  -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

echo "▸ Importing into login keychain (pre-authorizing codesign)…"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P speechy -T /usr/bin/codesign -A

echo "✓ '$NAME' created. Rebuild with ./scripts/build_app.sh"
