cask "quickmd" do
  version "1.4.0"
  sha256 "4774a54ce78198a91c02940b984f775af3da83365721395253ffeda9442d7a75"

  url "https://github.com/b451c/quickmd/releases/download/v#{version}/QuickMD-v#{version}.zip"
  name "QuickMD"
  desc "Lightning-fast native macOS Markdown viewer"
  homepage "https://qmd.app/"

  depends_on macos: ">= :ventura"

  app "QuickMD.app"

  zap trash: [
    "~/Library/Preferences/pl.falami.studio.QuickMD.plist",
    "~/Library/Saved Application State/pl.falami.studio.QuickMD.savedState",
  ]
end
