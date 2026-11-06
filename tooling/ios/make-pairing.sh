#!/usr/bin/env bash
# One-time pairing for the on-device phone runner.
#
# The iPhone must be connected with a data USB cable and unlocked. The tool may ask you to tap
# Trust on the phone. The resulting file is copied into the app's Documents folder, where the
# self-runner reads it. After that the Mac can be unplugged.
#
#   tooling/ios/make-pairing.sh <device-udid> [output.plist]
#
# The bundle id is the one the local project signs with.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UDID="$1"
if [ -z "$UDID" ]; then echo "usage: make-pairing.sh <device-udid> [output.plist]" >&2; exit 1; fi
OUT="$ROOT/.build/pairingFile.plist"
if [ $# -ge 2 ]; then OUT="$2"; fi
BUNDLE_ID=${BUNDLE_ID:-io.github.menghuan1918.dshgo}
SRC="$ROOT/.build/idevice"

if [ ! -x "$SRC/target/release/idevice-tools" ]; then
  if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$(dirname "$SRC")"
    git clone -q https://github.com/jkcoxson/idevice.git "$SRC"
    git -C "$SRC" checkout -q 3854a5d
  fi
  cargo build --release -p idevice-tools --manifest-path "$SRC/Cargo.toml"
fi

mkdir -p "$(dirname "$OUT")"
"$SRC/target/release/idevice-tools" --udid "$UDID" rppairing pair dsh-go-iphone "$OUT"

echo "Pairing file: $OUT"
echo "Copying it into $BUNDLE_ID/Documents/pairingFile.plist ..."
xcrun devicectl device copy to \
  --device "$UDID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source "$OUT" \
  --destination Documents/pairingFile.plist
echo "Done. Open DSH Go once so the file is picked up, and keep LocalDevVPN on."
