#!/bin/sh
# Builds build/Voicebox.app with SwiftPM, makes its icon from Resources/AppIcon.png, and signs it.
# SIGN_IDENTITY selects the certificate. The default "-" is an ad-hoc signature.
set -eu

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Voicebox.app"

swift build -c "$CONFIG" --product Voicebox
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Voicebox" "$APP/Contents/MacOS/Voicebox"
swift scripts/make-icon.swift Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
