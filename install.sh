#!/bin/sh
# Installs (or updates) T3 Proxy from this repository's GitHub releases.
#
#   curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh -s -- --version 0.1.0
#   curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh -s -- --uninstall
#
# It downloads T3-Proxy.zip and its SHA-256 from the release, checks both and the app's code signature,
# and copies "T3 Proxy.app" to /Applications (or ~/Applications when /Applications isn't writable).
# It never installs or starts the CLIProxyAPI hub and never touches its config.
set -eu

REPO="ImRLopezAG/t3-proxy"
APP="T3 Proxy.app"
BUNDLE_ID="dev.t3proxy.app"
VERSION=""
UNINSTALL=0

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || fail "--version needs a value"; VERSION="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" 2>/dev/null || true; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

quit_app() { osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true; sleep 1; }

if [ "$UNINSTALL" -eq 1 ]; then
  quit_app
  for dir in /Applications "$HOME/Applications"; do
    [ -d "$dir/$APP" ] && rm -rf "$dir/$APP" && say "Removed $dir/$APP"
  done
  say "Settings and history were kept: ~/Library/Application Support/T3 Proxy and the $BUNDLE_ID preferences."
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || fail "T3 Proxy is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] 2>/dev/null || fail "T3 Proxy needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."
[ "$(uname -m)" = "arm64" ] || fail "T3 Proxy is built for Apple silicon."
case "$VERSION" in ""|[0-9]*.[0-9]*.[0-9]*) ;; *) fail "version must look like 1.2.3" ;; esac

if [ -n "$VERSION" ]; then BASE="https://github.com/$REPO/releases/download/v$VERSION"
else BASE="https://github.com/$REPO/releases/latest/download"; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

say "Downloading T3 Proxy${VERSION:+ $VERSION}…"
curl -fsSL --proto '=https' --tlsv1.2 "$BASE/T3-Proxy.zip" -o "$TMP/T3-Proxy.zip" || fail "download failed ($BASE/T3-Proxy.zip)"
curl -fsSL --proto '=https' --tlsv1.2 "$BASE/T3-Proxy.zip.sha256" -o "$TMP/T3-Proxy.zip.sha256" || fail "checksum download failed"

expected=$(awk '{print $1; exit}' "$TMP/T3-Proxy.zip.sha256")
actual=$(shasum -a 256 "$TMP/T3-Proxy.zip" | awk '{print $1}')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch: the download is not the published build."

mkdir "$TMP/x"
ditto -x -k "$TMP/T3-Proxy.zip" "$TMP/x"
[ -d "$TMP/x/$APP" ] || fail "the archive does not contain $APP"
codesign --verify --strict --deep "$TMP/x/$APP" 2>/dev/null || fail "the app's code signature is invalid."
[ "$(defaults read "$TMP/x/$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BUNDLE_ID" ] || fail "unexpected bundle identifier."

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

quit_app
rm -rf "$DEST/$APP"
ditto "$TMP/x/$APP" "$DEST/$APP"
# Builds are ad-hoc signed until a notarized release exists; a curl download carries no quarantine flag,
# but clear it in case the archive was fetched another way.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

installed=$(defaults read "$DEST/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "Installed T3 Proxy $installed in $DEST."
say "Next: run the CLIProxyAPI hub (brew install cliproxyapi), then enter its management key in"
say "T3 Proxy → Settings → Connection. Settings → Getting Started shows what's left."
open "$DEST/$APP"
