cask "quickmd" do
  version "1.6.0"
  sha256 "df777871c4cba400c9e5520a525bfd7ad49acf25c20ae22d85a7eab4412711cc"

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
