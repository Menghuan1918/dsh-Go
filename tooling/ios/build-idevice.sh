#!/usr/bin/env bash
# Builds libidevice_ffi.a for the device and simulator. Run once before the first Xcode build.
# See tooling/ios/idevice/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/.build/idevice"
PATCH="$ROOT/tooling/ios/idevice/idevice.patch"
PROBE="$ROOT/tooling/ios/idevice/probe.rs"
OUT="$ROOT/app/ios/Idevice"
COMMIT=3854a5d
FEATURES="ring,obfuscate,core_device,tunnel_tcp_stack,tcp,installation_proxy,mobile_image_mounter,cryptexd,tss,heartbeat"

command -v cargo >/dev/null || { echo "cargo is required (rustup)" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode command line tools are required" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone -q https://github.com/jkcoxson/idevice.git "$SRC"
fi
git -C "$SRC" fetch -q origin "$COMMIT" || true
git -C "$SRC" checkout -q "$COMMIT"
git -C "$SRC" checkout -q -- .
git -C "$SRC" apply "$PATCH"
cp "$PROBE" "$SRC/ffi/src/core_device/probe.rs"

build() {
  local target="$1" sdk="$2" out="$3"
  echo "==> $target"
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  CARGO_PROFILE_RELEASE_LTO=false \
  RUSTFLAGS="-C embed-bitcode=no" \
    cargo build --release -p idevice-ffi --target "$target" --no-default-features \
      --features "$FEATURES" --manifest-path "$SRC/Cargo.toml"
  mkdir -p "$OUT/$out"
  cp "$SRC/target/$target/release/libidevice_ffi.a" "$OUT/$out/"
  cp "$SRC/ffi/idevice.h" "$OUT/idevice.h"
}

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
build aarch64-apple-ios iphoneos .
build aarch64-apple-ios-sim iphonesimulator sim-arm64
build x86_64-apple-ios iphonesimulator sim-x86_64
mkdir -p "$OUT/sim"
lipo -create "$OUT/sim-arm64/libidevice_ffi.a" "$OUT/sim-x86_64/libidevice_ffi.a" -output "$OUT/sim/libidevice_ffi.a"
rm -rf "$OUT/sim-arm64" "$OUT/sim-x86_64"
echo "==> idevice FFI ready in $OUT"
