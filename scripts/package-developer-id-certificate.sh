#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTIFICATE_CER="${1:-}"
PRIVATE_KEY="${2:-$ROOT_DIR/build/certificates/TappyDeveloperID.key}"
OUT_DIR="${3:-$ROOT_DIR/build/certificates}"
P12_PATH="$OUT_DIR/TappyDeveloperID.p12"
CERTIFICATE_PEM="$OUT_DIR/TappyDeveloperID.pem"

if [[ -z "$CERTIFICATE_CER" ]]; then
  echo "Usage: $0 /path/to/developer_id_application.cer [private-key] [output-dir]" >&2
  exit 1
fi

if [[ -z "${MACOS_CERTIFICATE_PASSWORD:-}" ]]; then
  echo "MACOS_CERTIFICATE_PASSWORD is required to protect the exported .p12" >&2
  exit 1
fi

if [[ ! -f "$CERTIFICATE_CER" ]]; then
  echo "Certificate not found: $CERTIFICATE_CER" >&2
  exit 1
fi

if [[ ! -f "$PRIVATE_KEY" ]]; then
  echo "Private key not found: $PRIVATE_KEY" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

openssl x509 -inform DER -in "$CERTIFICATE_CER" -out "$CERTIFICATE_PEM"
openssl pkcs12 -export \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE_PEM" \
  -out "$P12_PATH" \
  -passout "pass:$MACOS_CERTIFICATE_PASSWORD"

base64 -i "$P12_PATH" -o "$P12_PATH.base64"
chmod 600 "$P12_PATH" "$P12_PATH.base64"

echo "Created $P12_PATH"
echo "Created $P12_PATH.base64"
