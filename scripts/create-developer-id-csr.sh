#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/build/certificates}"
KEY_PATH="$OUT_DIR/TappyDeveloperID.key"
CSR_PATH="$OUT_DIR/TappyDeveloperID.certSigningRequest"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

if [[ -e "$KEY_PATH" || -e "$CSR_PATH" ]]; then
  echo "Refusing to overwrite existing certificate files in $OUT_DIR" >&2
  exit 1
fi

openssl genrsa -out "$KEY_PATH" 2048
chmod 600 "$KEY_PATH"
openssl req -new \
  -key "$KEY_PATH" \
  -out "$CSR_PATH" \
  -subj "/CN=Tappy Developer ID/O=Tappy/C=US"

echo "Created private key: $KEY_PATH"
echo "Created CSR: $CSR_PATH"
echo "Upload the CSR to Apple Developer when creating a Developer ID Application certificate."
