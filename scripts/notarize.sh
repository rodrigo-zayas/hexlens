#!/bin/zsh
# Notariza dist/HexLens.app y dist/hexlens con Apple y grapa el ticket a la app.
# Ejecutar después de build-app.sh con HEXLENS_SIGN_IDENTITY.
# Credenciales, una de dos:
#   NOTARY_PROFILE: perfil guardado con `xcrun notarytool store-credentials`.
#   APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID: API key de App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
else
  auth=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/payload"
ditto dist/HexLens.app "$tmp/payload/HexLens.app"
cp dist/hexlens "$tmp/payload/hexlens"
ditto -c -k "$tmp/payload" "$tmp/notarize.zip"

out=$(xcrun notarytool submit "$tmp/notarize.zip" "${auth[@]}" --wait --output-format json)
id=$(plutil -extract id raw - <<<"$out")
notary_status=$(plutil -extract status raw - <<<"$out")
echo "Notarización $id: $notary_status"
if [[ "$notary_status" != "Accepted" ]]; then
  xcrun notarytool log "$id" "${auth[@]}"
  exit 1
fi

for attempt in 1 2 3 4 5; do
  xcrun stapler staple dist/HexLens.app && exit 0
  echo "stapler falló (intento $attempt), reintento en 30 s"
  sleep 30
done
exit 1
