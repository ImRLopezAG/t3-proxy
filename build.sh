#!/bin/sh
# Builds dist/T3 Proxy.app. Does not install or touch the proxy service.
#
# Signing: ad-hoc by default (this Mac only; Gatekeeper blocks copies downloaded elsewhere).
# With T3_SIGN_IDENTITY set to a "Developer ID Application: … (TEAMID)" identity from your keychain, the app is
# signed for distribution: hardened runtime and a secure timestamp. Notarize with tools/release.sh.
set -eu
cd "$(dirname "$0")"
IDENTITY="${T3_SIGN_IDENTITY:--}"
swift test
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="dist/T3 Proxy.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/T3Proxy" "$APP/Contents/MacOS/"; cp App/Info.plist "$APP/Contents/"
cp -R "$BIN/T3Proxy_T3ProxyUI.bundle" "$APP/Contents/Resources/"
T=$(mktemp -d); swift tools/make-icon.swift design/references/t3-proxy-icon.png "$T/i.png"
mkdir "$T/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/i.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$T/i.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; rm -rf "$T"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  # The resource bundle holds no code, so only the app itself is signed (no --deep, as Apple recommends).
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "Built $APP ($( [ "$IDENTITY" = "-" ] && echo "ad-hoc signed" || echo "signed: $IDENTITY" ))"
