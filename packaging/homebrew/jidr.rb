# Template only: no JIdr Plus Homebrew tap is currently published.
# Fill version and checksum after creating a JIdr Plus release.
cask "jidr-plus" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/hbdzh/JIdr-plus/releases/download/v#{version}/Jidr-#{version}-arm64.dmg"
  name "JIdr Plus"
  desc "Android emulators with one-click rooted devices"
  homepage "https://github.com/hbdzh/JIdr-plus"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Jidr.app"
  binary "#{appdir}/Jidr.app/Contents/Helpers/jidr"

  uninstall quit: "ly.jidr.Jidr"
end
