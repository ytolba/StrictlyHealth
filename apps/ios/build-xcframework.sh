#!/bin/bash
# Build the shared Rust core (oura-core) for iOS device + simulator and package the
# OuraCore.xcframework the app links. Re-run after changing any Rust core code.
#
# The simulator-only dev harness (OuraApp/build_run.sh) refreshes just the sim slice;
# this produces BOTH slices, which a device build / TestFlight archive needs.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
HEADERS="$REPO/apps/ios/generated/headers"   # UniFFI header + module.modulemap
OUT="$REPO/apps/ios/OuraCore.xcframework"
LIB="liboura_core.a"

for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

echo "==> regenerate matching Swift bindings and headers"
cargo build -p oura-core
cargo run -p oura-core --bin uniffi-bindgen -- generate \
  --library "$REPO/target/debug/liboura_core.dylib" --language swift \
  --out-dir "$REPO/apps/ios/generated"
cp "$REPO/apps/ios/generated/oura_coreFFI.h" "$HEADERS/oura_coreFFI.h"

echo "==> build oura-core (release) for device + simulator"
cargo build -p oura-core --release --target aarch64-apple-ios
cargo build -p oura-core --release --target aarch64-apple-ios-sim

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/openhealth-framework.XXXXXX")
echo "==> create xcframework"
xcodebuild -create-xcframework \
  -library "$REPO/target/aarch64-apple-ios/release/$LIB"     -headers "$HEADERS" \
  -library "$REPO/target/aarch64-apple-ios-sim/release/$LIB" -headers "$HEADERS" \
  -output "$STAGE/OuraCore.xcframework"
if [ -e "$OUT" ]; then
  mv "$OUT" "$STAGE/previous.xcframework"
  echo "Previous framework preserved in $STAGE/previous.xcframework"
fi
mv "$STAGE/OuraCore.xcframework" "$OUT"
echo "✓ $OUT"
