#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$ROOT_DIR/build/certificates/github-secrets.env}"
P12_PATH="${P12_PATH:-$ROOT_DIR/build/certificates/TappyDeveloperID.p12}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-$ROOT_DIR/build/certificates/TappyLocalSigning.keychain-db}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/build/Tappy.dmg}"

read_secret() {
  local key="$1"
  local value="${!key:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return
  fi

  if [[ -f "$SECRETS_FILE" ]]; then
    awk -v key="$key" '
      index($0, key "=") == 1 {
        sub("^[^=]*=", "")
        print
        exit
      }
    ' "$SECRETS_FILE"
  fi
}

APPLE_ID="$(read_secret APPLE_ID)"
APPLE_TEAM_ID="$(read_secret APPLE_TEAM_ID)"
APPLE_APP_SPECIFIC_PASSWORD="$(read_secret APPLE_APP_SPECIFIC_PASSWORD)"
MACOS_CERTIFICATE_PASSWORD="$(read_secret MACOS_CERTIFICATE_PASSWORD)"
KEYCHAIN_PASSWORD="$(read_secret KEYCHAIN_PASSWORD)"

required_vars=(
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
  MACOS_CERTIFICATE_PASSWORD
  KEYCHAIN_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "$var_name is required. Check $SECRETS_FILE or export it in your shell." >&2
    exit 1
  fi
done

if [[ ! -f "$P12_PATH" ]]; then
  echo "Developer ID .p12 not found: $P12_PATH" >&2
  exit 1
fi

rm -f "$KEYCHAIN_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$P12_PATH" -P "$MACOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

existing_keychains="$(security list-keychains -d user | tr -d '"')"
security list-keychains -d user -s "$KEYCHAIN_PATH" $existing_keychains

SIGN_APP=1 \
APPLE_TEAM_ID="$APPLE_TEAM_ID" \
CODE_SIGN_IDENTITY="Developer ID Application" \
"$ROOT_DIR/scripts/build-dmg.sh" "$DMG_PATH"

APPLE_ID="$APPLE_ID" \
APPLE_TEAM_ID="$APPLE_TEAM_ID" \
APPLE_APP_SPECIFIC_PASSWORD="$APPLE_APP_SPECIFIC_PASSWORD" \
"$ROOT_DIR/scripts/notarize-dmg.sh" "$DMG_PATH"

echo "Manual notarized release artifact:"
echo "$DMG_PATH"
echo "$DMG_PATH.sha256"
