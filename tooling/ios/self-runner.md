# On-device (self-runner) phone control

The original design runs PhoneRunner as an XCUITest from a Mac. The self-runner makes the app its
own trusted host instead: the Mac is needed once, to make a pairing file, and never at run time.

## One-time setup

1. On the iPhone, install LocalDevVPN from the App Store and turn it on. It maps 10.7.0.1 back to
   this phone, which is how the app reaches its own developer services on a free Apple ID.
2. Connect the iPhone with a data USB cable, unlock it, and tap Trust if asked.
3. Run:

       tooling/ios/make-pairing.sh <device-udid>

   It builds idevice-tools, creates pairingFile.plist, and copies it into the app's Documents
   folder. The pairing file is a host identity: keep it private. Make a new one after Reset Location
   and Privacy or if Developer Mode is turned off.
4. Open DSH Go once and allow Local Network when iOS asks. The first phone tool call downloads and
   mounts the developer disk image; it can take a minute.

## What changes

- No App Group and no paid Apple team. The app and the pairing file are signed with the normal
  development identity; LocalDevVPN supplies the loopback path.
- Screenshots, touches, hardware keys and app launches go through CoreDevice, not XCTest. The Mac
  can be unplugged.
- There is no element tree. screen returns a screenshot and a screen number; use
  tap_xy(observation, x, y) with screenshot pixel coordinates. tap by element id, type by element
  id and collect are not available; the app answers with an instruction to use tap_xy/screen.
- Typing is ASCII only (US keyboard layout). Chinese text, passwords and verification codes must
  use handoff.
- The old Mac runner is still the fallback when no pairingFile.plist exists.

## Known gaps

- Passwords and secure fields are not detected (there is no accessibility tree), so the old
  refuse-secure-fields guarantee is not enforced by the self-runner yet. The 30-minute user grant
  and the model instruction still apply; do not type passwords.
- Background execution while the agent is in another app depends on the engine's existing
  background grant. If iOS suspends it, the tunnel stops until the app returns.
- The AX audit service (com.apple.accessibility.axAuditDaemon.remoteserver) could restore the
  element tree and secure-field checks later; it speaks DTX and is not wired up yet.

## Build

tooling/ios/build-idevice.sh builds the Rust FFI; Xcode links app/ios/Idevice/libidevice_ffi.a and
reads the idevice module from app/ios/Idevice/module.modulemap. Build it once before the first
Xcode build. The .a files are gitignored.
