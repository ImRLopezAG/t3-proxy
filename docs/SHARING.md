# Sharing T3 Proxy

## Install

    curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh
    # or
    brew tap ImRLopezAG/t3-proxy https://github.com/ImRLopezAG/t3-proxy && brew install --cask t3-proxy

## Publishing a release

    tools/package.sh                      # build, dist/T3-Proxy.zip + .sha256, version/checksum into Casks/t3-proxy.rb
    git commit -am "Release <version>" && git tag v<version> && git push && git push --tags
    gh release create v<version> dist/T3-Proxy.zip dist/T3-Proxy.zip.sha256

## What the person you share it with needs

1. **A Mac on macOS 26 with Apple silicon.**
2. **The CLIProxyAPI hub on that Mac.** Install it with `brew install cliproxyapi` and start it. Then sign their own
   Claude and Codex subscriptions into the hub; T3 Proxy never sees anyone else's accounts.
3. **The hub's management key.** Enter it in T3 Proxy → Settings → Connection. It is stored in their Keychain and
   only sent to 127.0.0.1. If their hub doesn't listen on 8317, set the port on the same pane.
4. **Optional: T3 Code**, for the Threads tab (Settings → T3 Code).
5. **Optional: usage history.** Turn on recording in Settings (Getting Started). T3 Proxy then reads the hub's usage
   queue and keeps the history in `~/Library/Application Support/T3 Proxy/usage.sqlite`. Reading the queue removes the
   records from it, so leave this off if another app (such as Proxy Deck) already records usage from the same hub.
   T3 Proxy refuses to record while Proxy Deck's database is present.

Settings → Getting Started shows the same checklist with live check marks.

## Building a copy to share

| Build | Command | What the other person sees |
|---|---|---|
| Ad-hoc (default) | `./build.sh` | Gatekeeper blocks it. They right-click → Open, or run `xattr -dr com.apple.quarantine "T3 Proxy.app"`. Every update asks for Keychain access again. |
| Developer ID, notarized | `tools/release.sh` (see its header) | Opens normally. Keychain access survives updates. |

A notarized build needs an Apple Developer Program membership, a **Developer ID Application** certificate, and a
`notarytool` keychain profile; `tools/release.sh` explains the one-time setup and writes `dist/T3-Proxy-<version>.zip`.
