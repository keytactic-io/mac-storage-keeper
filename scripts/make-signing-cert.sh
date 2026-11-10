#!/bin/zsh
# Creates a self-signed code-signing certificate in your login keychain.
#
# Why: macOS ties Full Disk Access to an app's code signature. An ad-hoc signature changes
# on every build, so the permission silently stops applying after each rebuild. Signing with
# the same certificate every time keeps the permission across rebuilds.
#
# Remove later with:  security delete-identity -c "Storage Keeper Local Signing"
set -euo pipefail

NAME="Storage Keeper Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
  echo "Signing identity '$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# LibreSSL (/usr/bin/openssl) produces a PKCS#12 file that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -name "$NAME" -passout pass:storagekeeper
security import "$TMP/id.p12" -k "$KEYCHAIN" -P storagekeeper -T /usr/bin/codesign >/dev/null

echo "Created signing identity '$NAME' in your login keychain."
