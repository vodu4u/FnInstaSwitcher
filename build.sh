#!/bin/sh
# Builds InstantFn.app with the Command Line Tools only (no Xcode needed).
#   ./build.sh            → Debug build (latency diagnostics in Advanced menu)
#   ./build.sh release    → Release build, universal (Apple Silicon + Intel)
#   SIGN_ID="Developer ID Application: …" ./build.sh release
#       → sign with a real identity. Default is ad-hoc ("-"); macOS then ties the
#         Input Monitoring grant to this exact build, so it must be re-granted after
#         every rebuild.
#   ARCHS="arm64" ./build.sh release   → single-architecture build
set -eu
cd "$(dirname "$0")"
CONFIG="${1:-debug}"
BUNDLE_ID="io.github.vodu4u.InstantFn"
MIN_OS="13.0"
OUT="build/$CONFIG/InstantFn.app"

case "$CONFIG" in
  debug)   FLAGS="-Onone -g -D DEBUG"; ARCHS="${ARCHS:-arm64}" ;;
  release) FLAGS="-O -whole-module-optimization"; ARCHS="${ARCHS:-arm64 x86_64}" ;;
  *) echo "usage: $0 [debug|release]"; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "build/$CONFIG/obj"
cp InstantFn/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"   # regenerate: swift tools/make-icon.swift

SLICES=""
for ARCH in $ARCHS; do
  # shellcheck disable=SC2086
  swiftc $FLAGS -swift-version 5 -target "$ARCH-apple-macos$MIN_OS" \
    -module-name InstantFn -o "build/$CONFIG/obj/InstantFn-$ARCH" InstantFn/*.swift
  SLICES="$SLICES build/$CONFIG/obj/InstantFn-$ARCH"
done
# shellcheck disable=SC2086
lipo -create $SLICES -output "$OUT/Contents/MacOS/InstantFn"

sed -e "s/\$(EXECUTABLE_NAME)/InstantFn/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_OS/" \
    InstantFn/Info.plist > "$OUT/Contents/Info.plist"
plutil -lint "$OUT/Contents/Info.plist" >/dev/null

if [ "${SIGN_ID:--}" = "-" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi
codesign --force --options runtime $TS \
  --entitlements InstantFn/InstantFn.entitlements \
  --sign "${SIGN_ID:--}" "$OUT"
codesign --verify --strict "$OUT"
echo "Built $OUT ($(lipo -archs "$OUT/Contents/MacOS/InstantFn"))"
