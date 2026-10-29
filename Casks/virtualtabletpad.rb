cask "virtualtabletpad" do
  version "2.0.0"
  sha256 :no_check

  url "https://github.com/Lambda-404/VirtualTabletPad/releases/download/v#{version}/VirtualTabletPad-v#{version}.dmg"
  name "VirtualTabletPad"
  desc "Transform iPad into a graphics tablet and multi-touch trackpad for Mac"
  homepage "https://github.com/Lambda-404/VirtualTabletPad"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "VirtualTabletPad.app"

  zap trash: [
    "~/Library/Application Support/VirtualTabletPad",
    "~/Library/Caches/com.vpad.MacHost",
    "~/Library/Preferences/com.vpad.MacHost.plist",
  ]
end
