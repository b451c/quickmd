cask "quickmd" do
  version "1.7.0"
  sha256 "4e5a92bb8861c5f8cdc1f68522398894bbb6f4cfd040009b83fd5be42ff47175"

  url "https://github.com/b451c/quickmd/releases/download/v#{version}/QuickMD-v#{version}.zip",
      verified: "github.com/b451c/quickmd/"
  name "QuickMD"
  desc "Lightning-fast native Markdown viewer"
  homepage "https://qmd.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "QuickMD.app"

  zap trash: [
    "~/Library/Preferences/pl.falami.studio.QuickMD.plist",
    "~/Library/Saved Application State/pl.falami.studio.QuickMD.savedState",
  ]
end
