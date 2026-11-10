#!/bin/sh
# Packs dist/T3 Proxy.app as dist/T3-Proxy.zip + dist/T3-Proxy.zip.sha256 (the release assets that install.sh and
# the Homebrew cask download) and writes the version and checksum into Casks/t3-proxy.rb.
# Builds first with ./build.sh (ad-hoc, or Developer ID when T3_SIGN_IDENTITY is set). Publishing is separate:
#   git tag v<version> && git push --tags
#   gh release create v<version> dist/T3-Proxy.zip dist/T3-Proxy.zip.sha256
set -eu
cd "$(dirname "$0")/.."
./build.sh
APP="dist/T3 Proxy.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
rm -f dist/T3-Proxy.zip dist/T3-Proxy.zip.sha256
/usr/bin/ditto -c -k --keepParent "$APP" dist/T3-Proxy.zip
SUM=$(shasum -a 256 dist/T3-Proxy.zip | awk '{print $1}')
printf '%s  T3-Proxy.zip\n' "$SUM" > dist/T3-Proxy.zip.sha256
/usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SUM\"/" Casks/t3-proxy.rb
echo "Packed T3 Proxy $VERSION → dist/T3-Proxy.zip (sha256 $SUM); Casks/t3-proxy.rb updated."
