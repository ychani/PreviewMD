# Draft cask for the ychani/homebrew-tap repository (Casks/previewmd.rb).
# On each release: bump `version`, then set `sha256` to the output of
#   shasum -a 256 dist/PreviewMD-<version>.dmg
cask "previewmd" do
  version "0.5.1"
  sha256 "728dfaf3c167a92b561d2a9088436d6b8f717bc8efb3f41f599a9d8c8708a77c"

  url "https://github.com/ychani/PreviewMD/releases/download/v#{version}/PreviewMD-#{version}.dmg"
  name "PreviewMD"
  desc "Markdown reader with a Quick Look extension"
  homepage "https://github.com/ychani/PreviewMD"

  depends_on macos: :ventura # i.e. macOS 13 or later

  app "PreviewMD.app"

  zap trash: [
    "~/Library/Caches/com.narnarlabs.previewmd",
    "~/Library/Containers/com.narnarlabs.previewmd.quicklook",
    "~/Library/HTTPStorages/com.narnarlabs.previewmd",
    "~/Library/Preferences/com.narnarlabs.previewmd.plist",
    "~/Library/Saved Application State/com.narnarlabs.previewmd.savedState",
    "~/Library/WebKit/com.narnarlabs.previewmd",
  ]
end
