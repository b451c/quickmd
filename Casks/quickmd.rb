cask "quickmd" do
  version "1.10.0"
  sha256 "f4dc081c58ec35a43727857bd8611a8114fd3badda8cc1ba3f3fe96cb1d60953"

  url "https://github.com/b451c/quickmd/releases/download/v#{version}/QuickMD-v#{version}.zip",
      verified: "github.com/b451c/quickmd/"
  name "QuickMD"
  desc "Lightning-fast native Markdown viewer"
  homepage "https://qmd.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "QuickMD.app"

  zap trash: [
    "~/Library/Preferences/pl.falami.studio.QuickMD.plist",
    "~/Library/Saved Application State/pl.falami.studio.QuickMD.savedState",
  ]
end
