cask "lanki" do
  version "2.0.0"
  # Regenerate on every release: `shasum -a 256 Lankiv<version>.dmg`.
  # The `update-cask.yml` workflow overwrites this automatically on release.
  sha256 "0c224c52f185f1ad44abda6f0450c4ed5f96a1075e9c0c9d93105116ec455774"

  url "https://github.com/rGradov/lanki/releases/download/v#{version}/Lankiv#{version}.dmg"
  name "Lanki"
  desc "Native macOS menu-bar language-learning assistant"
  homepage "https://github.com/rGradov/lanki"

  depends_on macos: :sonoma

  app "Lanki.app"

  zap trash: [
    "~/Library/Application Support/Lanki",
    "~/Library/Preferences/com.lanki.app.plist",
  ]
end
