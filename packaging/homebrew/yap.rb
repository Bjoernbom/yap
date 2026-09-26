# Template for Casks/yap.rb in the Bjoernbom/homebrew-tap repository.
# scripts/release/render-cask.sh fills in @VERSION@ and @SHA256@; the
# release workflow prints the result in its summary. See docs/RELEASING.md.
cask "yap" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Bjoernbom/yap/releases/download/v#{version}/yap-#{version}.zip"
  name "yap"
  desc "Push-to-talk dictation and meeting notes that run on-device"
  homepage "https://github.com/Bjoernbom/yap"

  livecheck do
    url "https://raw.githubusercontent.com/Bjoernbom/yap/main/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # Sparkle updates the app in place after install.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "yap.app"

  # yap is signed but not notarized (no paid Apple account). Without the
  # quarantine flag Gatekeeper doesn't block the first launch; the stable
  # signature is what macOS permissions are tied to.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-d", "-r", "com.apple.quarantine", "#{appdir}/yap.app"]
  end

  uninstall quit: "com.bjornbom.yap"

  # Notes in ~/Documents/yap are the user's and stay.
  zap trash: [
    "~/Library/Application Support/yap",
    "~/Library/Caches/com.bjornbom.yap",
    "~/Library/HTTPStorages/com.bjornbom.yap",
    "~/Library/Preferences/com.bjornbom.yap.plist",
  ]
end
