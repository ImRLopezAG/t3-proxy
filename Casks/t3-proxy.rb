cask "t3-proxy" do
  version "0.2.1"
  sha256 "818e96c93e76edc8e483cf1f014179238117d69b2177b6d2e8910c042f5332a9"

  url "https://github.com/ImRLopezAG/t3-proxy/releases/download/v#{version}/T3-Proxy.zip"
  name "T3 Proxy"
  desc "Menu bar companion for a local CLIProxyAPI hub"
  homepage "https://github.com/ImRLopezAG/t3-proxy"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "T3 Proxy.app"

  # Releases are ad-hoc signed until a notarized build exists; without this Gatekeeper refuses to open the app.
  # Runs in the staging folder (the steps' default base), before the app is moved to /Applications.
  preflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "T3 Proxy.app"],
                          chdir: ".", writable_paths: ["T3 Proxy.app"]
  end

  uninstall quit: "dev.t3proxy.app"

  zap trash: [
    "~/Library/Application Support/T3 Proxy",
    "~/Library/Preferences/dev.t3proxy.app.plist",
  ]

  caveats <<~EOS
    T3 Proxy reads a local CLIProxyAPI hub; it never installs or starts it:
      brew install cliproxyapi
    Then enter the hub's management key in T3 Proxy → Settings → Connection.
  EOS
end
