#!/bin/zsh
# CI only: puts the signing certificate in a temporary keychain and saves its
# identity as SIGN_IDENTITY for build.sh.
#   tools/import_signing_cert.sh <file.p12> <password>
set -e
P12=$1 PASSWORD=$2
KC=$RUNNER_TEMP/signing.keychain-db

security create-keychain -p "" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "" "$KC"
security import "$P12" -k "$KC" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null
security list-keychains -d user -s "$KC" ${(f)"$(security list-keychains -d user | tr -d '" ')"}

ID=$(security find-identity -p codesigning "$KC" | awk '/"MultiDock Signing"/ { print $2; exit }')
if [[ -z "$ID" ]]; then
  echo "Couldn't find the MultiDock Signing identity in the certificate." >&2
  exit 1
fi
echo "SIGN_IDENTITY=$ID" >> "$GITHUB_ENV"
echo "Signing with $ID"
