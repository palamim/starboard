cask "starboard" do
  version "0.8.3"
  sha256 "415dfd0af2988a7d601825afca0a7d8e561a12cd7574af592040b5c342af9514"

  url "https://github.com/palamim/starboard/releases/download/v#{version}/Starboard.zip"
  name "Starboard"
  desc "Terminal that sits permanently beside the Dock" # Cask desc must not include the platform.
  homepage "https://github.com/palamim/starboard"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Bare symbol means ">= this release". Package.swift pins .macOS(.v13).
  depends_on macos: :ventura

  app "Starboard.app"

  uninstall quit: "com.starboard.app"

  zap trash: "~/Library/Logs/Starboard.log"

  caveats <<~EOS
    Starboard is ad-hoc signed but not notarized, so macOS blocks the first
    launch. To approve it:

      1. Open Starboard and click Done on the block dialog.
      2. System Settings -> Privacy & Security -> Open Anyway (next to the
         Starboard entry), then confirm and enter your password.

    Starboard then asks for Accessibility permission, which it uses to read
    the Dock's live position. Without it Starboard still runs, just pinned
    to a fixed corner instead of hugging the Dock.

    Upgrading replaces Starboard.app in place, which silently invalidates
    that Accessibility grant: System Settings keeps listing Starboard as
    allowed while it no longer is, and un-ticking and re-ticking the
    checkbox does not fix it. After upgrading, run

      tccutil reset Accessibility com.starboard.app

    then relaunch Starboard and accept the fresh prompt.

    To start Starboard at login, add it under System Settings -> General ->
    Login Items & Extensions.
  EOS
end
