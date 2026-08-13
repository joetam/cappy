cask "cappy" do
  version "0.1.13"
  sha256 "666265cc312011c0bea311e5fe385ed8e7b1ccee7f22f18d463216115cd92ca1"

  url "https://github.com/joetam/cappy/releases/download/v#{version}/Cappy-#{version}-macos-arm64.dmg"
  name "Cappy"
  desc "Track usage limits across coding accounts"
  homepage "https://github.com/joetam/cappy"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Cappy.app"
end
