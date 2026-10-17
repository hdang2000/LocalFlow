#!/bin/sh
# Creates a self-signed code-signing certificate in a dedicated keychain so
# macOS privacy grants (Accessibility, Microphone) survive rebuilds.
# The keychain password is random and stored next to it, readable only by you.
set -eu
S="$HOME/Library/Application Support/LocalFlow/signing"
KC="$S/localflow-signing.keychain-db"
[ -f "$KC" ] && { echo "Already exists: $KC"; exit 0; }
mkdir -p "$S"; chmod 700 "$S"
openssl rand -hex 16 > "$S/keychain-password"; chmod 600 "$S/keychain-password"
KP=$(cat "$S/keychain-password")
security create-keychain -p "$KP" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KP" "$KC"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=LocalFlow Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > "$d/c.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/k.pem" -out "$d/c.pem" -days 3650 -config "$d/c.cnf" 2>/dev/null
pw=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$d/k.pem" -in "$d/c.pem" -out "$d/id.p12" -passout "pass:$pw" -name "LocalFlow Local Signing"
security import "$d/id.p12" -k "$KC" -P "$pw" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KP" "$KC" >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "Created signing identity in $KC"
