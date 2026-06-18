#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Tappy"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/build/DerivedData}"
STAGING_DIR="${STAGING_DIR:-$ROOT_DIR/build/dmg-staging}"
DMG_PATH="${1:-$ROOT_DIR/build/Tappy.dmg}"
RW_DMG_PATH="${DMG_PATH%.dmg}-rw.dmg"
SIGN_APP="${SIGN_APP:-0}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"

MOUNT_DIR=""

cleanup_mount() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}

trap cleanup_mount EXIT

create_dmg_background() {
  local output_path="$1"

  /usr/bin/swift - "$output_path" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let width = 640
let height = 400

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not create DMG background bitmap.")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let canvas = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
NSColor(calibratedRed: 0.965, green: 0.973, blue: 0.984, alpha: 1).setFill()
canvas.fill()

let accent = NSColor(calibratedRed: 0.075, green: 0.455, blue: 0.980, alpha: 1)
let ink = NSColor(calibratedRed: 0.105, green: 0.118, blue: 0.145, alpha: 1)
let muted = NSColor(calibratedRed: 0.395, green: 0.430, blue: 0.490, alpha: 1)

func centered(_ text: String, y: CGFloat, height: CGFloat, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (text as NSString).draw(
        in: NSRect(x: 40, y: y, width: CGFloat(width - 80), height: height),
        withAttributes: attrs
    )
}

centered(
    "Drag Tappy to Applications",
    y: 322,
    height: 38,
    font: NSFont.systemFont(ofSize: 29, weight: .bold),
    color: ink
)

centered(
    "Then open Tappy from your Applications folder.",
    y: 294,
    height: 24,
    font: NSFont.systemFont(ofSize: 14, weight: .medium),
    color: muted
)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 246, y: 214))
arrow.line(to: NSPoint(x: 394, y: 214))
arrow.lineWidth = 7
arrow.lineCapStyle = .round
accent.setStroke()
arrow.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 394, y: 214))
head.line(to: NSPoint(x: 367, y: 234))
head.move(to: NSPoint(x: 394, y: 214))
head.line(to: NSPoint(x: 367, y: 194))
head.lineWidth = 7
head.lineCapStyle = .round
head.lineJoinStyle = .round
accent.setStroke()
head.stroke()

let leftRing = NSBezierPath(ovalIn: NSRect(x: 119, y: 164, width: 82, height: 82))
accent.withAlphaComponent(0.10).setFill()
leftRing.fill()

let rightRing = NSBezierPath(ovalIn: NSRect(x: 439, y: 164, width: 82, height: 82))
accent.withAlphaComponent(0.10).setFill()
rightRing.fill()

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode DMG background PNG.")
}

try data.write(to: URL(fileURLWithPath: outputPath))
SWIFT
}

style_dmg_window() {
  local mount_dir="$1"

  /usr/bin/SetFile -a V "$mount_dir/.background" 2>/dev/null || /usr/bin/chflags hidden "$mount_dir/.background" 2>/dev/null || true

  /usr/bin/osascript <<APPLESCRIPT
set mountPath to "$mount_dir"

tell application "Finder"
  set dmgFolder to POSIX file mountPath as alias
  open dmgFolder
  delay 0.8

  set dmgWindow to container window of dmgFolder
  set current view of dmgWindow to icon view
  try
    set toolbar visible of dmgWindow to false
  end try
  try
    set statusbar visible of dmgWindow to false
  end try
  set bounds of dmgWindow to {120, 120, 760, 520}

  set viewOptions to icon view options of dmgWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 96
  set text size of viewOptions to 12
  set backgroundImage to POSIX file (mountPath & "/.background/background.png") as alias
  set background picture of viewOptions to backgroundImage

  set position of item "Tappy.app" of dmgFolder to {160, 218}
  set position of item "Applications" of dmgFolder to {480, 218}

  update dmgFolder without registering applications
  delay 1
  try
    close dmgWindow
  end try
end tell
APPLESCRIPT
}

rm -rf "$DERIVED_DATA_DIR" "$STAGING_DIR" "$DMG_PATH" "$DMG_PATH.sha256" "$RW_DMG_PATH"
mkdir -p "$(dirname "$DMG_PATH")" "$STAGING_DIR"

if [[ "$SIGN_APP" == "1" || "$SIGN_APP" == "true" ]]; then
  if [[ -z "$APPLE_TEAM_ID" ]]; then
    echo "APPLE_TEAM_ID or DEVELOPMENT_TEAM is required when SIGN_APP=1" >&2
    exit 1
  fi

  signing_args=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
else
  signing_args=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
  )
fi

xcodebuild \
  -project "$ROOT_DIR/Tappy.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  "${signing_args[@]}" \
  build

APP_PATH="$(find "$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION" -maxdepth 1 -type d -name "$APP_NAME.app" -print -quit)"

if [[ -z "$APP_PATH" ]]; then
  echo "Could not find $APP_NAME.app in $DERIVED_DATA_DIR/Build/Products/$CONFIGURATION" >&2
  exit 1
fi

if [[ "$SIGN_APP" == "1" || "$SIGN_APP" == "true" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
create_dmg_background "$STAGING_DIR/.background/background.png"
/usr/bin/SetFile -a V "$STAGING_DIR/.background" 2>/dev/null || /usr/bin/chflags hidden "$STAGING_DIR/.background" 2>/dev/null || true

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  "$RW_DMG_PATH"

MOUNT_OUTPUT="$(hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  "$RW_DMG_PATH")"
MOUNT_DIR="$(printf '%s\n' "$MOUNT_OUTPUT" | awk '/\/Volumes\// {for (i=3; i<=NF; i++) {if ($i ~ /^\/Volumes\//) {print substr($0, index($0,$i)); exit}}}')"

if [[ -z "$MOUNT_DIR" ]]; then
  echo "Could not determine mounted DMG path" >&2
  echo "$MOUNT_OUTPUT" >&2
  exit 1
fi

style_dmg_window "$MOUNT_DIR"
sync
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""

hdiutil convert \
  "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" \
  -ov

rm -f "$RW_DMG_PATH"

if [[ "$SIGN_APP" == "1" || "$SIGN_APP" == "true" ]]; then
  codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

echo "Created $DMG_PATH"
echo "Created $DMG_PATH.sha256"
