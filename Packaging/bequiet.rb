cask "bequiet" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/petrnymsa/be_quiet/releases/download/v#{version}/BeQuiet-#{version}.zip"
  name "BeQuiet"
  desc "Pauses Spotify, Apple Music and browser media while the microphone is in use"
  homepage "https://github.com/petrnymsa/be_quiet"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "BeQuiet.app"

  uninstall quit: "cz.nymsa.BeQuiet"

  zap trash: "~/Library/Preferences/cz.nymsa.BeQuiet.plist"

  caveats <<~EOS
    BeQuiet is ad-hoc signed (there is no Apple Developer account behind it),
    so Gatekeeper refuses the first launch. Allow it under System Settings →
    Privacy & Security → Open Anyway, or clear the quarantine flag:
      xattr -dr com.apple.quarantine "#{appdir}/BeQuiet.app"
    Browser tabs are paused only after "Allow JavaScript from Apple Events" is
    enabled in Chrome (View → Developer) and Safari (Develop menu).
  EOS
end
