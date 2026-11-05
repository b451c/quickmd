cask "quickmd" do
  version "1.14.4"
  sha256 "17677468c385bbe190c8770fe35843c41485bfe02ccbeca3210d8ee2ca4f0104"

  url "https://github.com/b451c/quickmd/releases/download/v#{version}/QuickMD-v#{version}.zip"
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
