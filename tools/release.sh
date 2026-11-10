#!/bin/sh
# Builds a Developer ID–signed, notarized and stapled T3 Proxy and packs it as dist/T3-Proxy-<version>.zip.
#
# One-time setup (needs an Apple Developer Program membership):
#   1. Create a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates).
#   2. Store notary credentials in your keychain; the password is an app-specific password from account.apple.com:
#        xcrun notarytool store-credentials T3ProxyNotary --apple-id <you@example.com> --team-id <TEAMID>
# Then:
#   T3_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" T3_NOTARY_PROFILE=T3ProxyNotary tools/release.sh
#
# Credentials never appear in this script: notarytool reads them from the keychain profile.
set -eu
cd "$(dirname "$0")/.."
: "${T3_SIGN_IDENTITY:?Set T3_SIGN_IDENTITY to your Developer ID Application identity}"
: "${T3_NOTARY_PROFILE:?Set T3_NOTARY_PROFILE to a notarytool keychain profile (see the header)}"
case "$T3_SIGN_IDENTITY" in "Developer ID Application:"*) ;; *) echo "T3_SIGN_IDENTITY must be a Developer ID Application identity" >&2; exit 1;; esac
if ! security find-identity -v -p codesigning | grep -Fq "\"$T3_SIGN_IDENTITY\""; then
  echo "No valid identity named \"$T3_SIGN_IDENTITY\" in your keychain" >&2; exit 1
fi

T3_SIGN_IDENTITY="$T3_SIGN_IDENTITY" ./build.sh
APP="dist/T3 Proxy.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
SUBMIT="dist/T3-Proxy-$VERSION-notarize.zip"
OUT="dist/T3-Proxy-$VERSION.zip"
rm -f "$SUBMIT" "$OUT"

/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$T3_NOTARY_PROFILE" --wait
rm -f "$SUBMIT"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$OUT"
echo "Ready to share: $OUT"
