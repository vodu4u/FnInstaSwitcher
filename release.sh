#!/bin/sh
# Builds a release zip for GitHub Releases: dist/InstantFn.zip (+ .sha256).
# The asset name has no version on purpose, so the README can always link to
# https://github.com/vodu4u/FnInstaSwitcher/releases/latest/download/InstantFn.zip
#
# Unsigned (default): ad-hoc signed; users open it once via
#   System Settings → Privacy & Security → Open Anyway.
#
# Signed + notarized (needs Apple Developer Program):
#   one-time:  xcrun notarytool store-credentials instantfn-notary \
#                --apple-id <apple id> --team-id <TEAMID> --password <app-specific password>
#   release:   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=instantfn-notary ./release.sh
set -eu
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" InstantFn/Info.plist)
APP=build/release/InstantFn.app
ZIP="dist/InstantFn.zip"

./build.sh release
mkdir -p dist
rm -f "$ZIP" "$ZIP.sha256"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ "${SIGN_ID:--}" != "-" ] || { echo "NOTARY_PROFILE needs SIGN_ID (Developer ID Application)"; exit 1; }
  ditto -c -k --keepParent "$APP" "dist/notarize.zip"
  xcrun notarytool submit "dist/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "dist/notarize.zip"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
( cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
echo "Release artifact for v$VERSION: $ZIP"
cat "$ZIP.sha256"
