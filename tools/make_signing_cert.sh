#!/bin/zsh
# Makes the certificate MultiDock releases are signed with. Signing every
# release with the same certificate is what lets macOS keep MultiDock's
# Accessibility permission across updates.
#
#   tools/make_signing_cert.sh --upload   # run once on your Mac: creates
#                                         # ~/MultiDock-signing.p12 and stores
#                                         # it as GitHub secrets for Release
#   tools/make_signing_cert.sh <file.p12> # just create one (used by CI tests)
#
# Keep ~/MultiDock-signing.p12 and its .password file somewhere safe. If the
# certificate is ever replaced, everyone has to allow Accessibility again.
set -e
cd "$(dirname "$0")/.."

UPLOAD=0
if [[ "$1" == "--upload" ]]; then UPLOAD=1; shift; fi
OUT=${1:-$HOME/MultiDock-signing.p12}
if [[ -e "$OUT" ]]; then
  echo "$OUT already exists. Releases must keep using the same certificate, so it won't be replaced." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = MultiDock Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# The system openssl (LibreSSL) writes .p12 files macOS's keychain can import.
PASS=$(/usr/bin/openssl rand -hex 24)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "MultiDock Signing" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout "pass:$PASS" -out "$OUT"
print -r -- "$PASS" > "$OUT.password"
chmod 600 "$OUT" "$OUT.password"
echo "Created $OUT (password in $OUT.password)"

if (( UPLOAD )); then
  base64 -i "$OUT" | gh secret set MULTIDOCK_CERT_P12
  gh secret set MULTIDOCK_CERT_PASSWORD --body "$PASS"
  echo "Stored MULTIDOCK_CERT_P12 and MULTIDOCK_CERT_PASSWORD as GitHub secrets."
fi
