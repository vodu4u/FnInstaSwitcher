#!/bin/sh
# Builds InstantFn.app with the Command Line Tools only (no Xcode needed).
#   ./build.sh            → Debug build (latency diagnostics shown in the menu)
#   ./build.sh release    → Release build
#   SIGN_ID="My Cert" ./build.sh release   → sign with a stable identity (recommended:
#       macOS ties the Input Monitoring grant to the code signature; with ad-hoc
#       signing every rebuild looks like a new app and must be re-granted).
set -eu
cd "$(dirname "$0")"
CONFIG="${1:-debug}"
BUNDLE_ID="com.instantfn.InstantFn"
MIN_OS="13.0"
OUT="build/$CONFIG/InstantFn.app"

case "$CONFIG" in
  debug)   FLAGS="-Onone -g -D DEBUG" ;;
  release) FLAGS="-O -whole-module-optimization" ;;
  *) echo "usage: $0 [debug|release]"; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp InstantFn/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"   # regenerate: swift tools/make-icon.swift
# shellcheck disable=SC2086
swiftc $FLAGS -swift-version 5 -target "arm64-apple-macos$MIN_OS" \
  -module-name InstantFn -o "$OUT/Contents/MacOS/InstantFn" InstantFn/*.swift

sed -e "s/\$(EXECUTABLE_NAME)/InstantFn/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_OS/" \
    InstantFn/Info.plist > "$OUT/Contents/Info.plist"
plutil -lint "$OUT/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none \
  --entitlements InstantFn/InstantFn.entitlements \
  --sign "${SIGN_ID:--}" "$OUT"
codesign --verify --strict "$OUT"
echo "Built $OUT"
