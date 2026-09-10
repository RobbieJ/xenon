#!/usr/bin/env bash
# Builds libopus (plus the Sotto ctl shim) as Packages/SottoKit/Vendor/opus.xcframework
# for iOS devices and the iOS simulator. Run on a Mac with Xcode 27 and CMake installed.
#
#   brew install cmake
#   Scripts/build-opus-xcframework.sh [opus-version]
#
# The package detects the xcframework and enables the Opus codec automatically (see Package.swift).
set -euo pipefail

OPUS_VERSION="${1:-1.6.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/sotto-opus-build"
OUT="$ROOT/Packages/SottoKit/Vendor/opus.xcframework"
SHIM="$ROOT/Scripts/opus-shim"

rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
curl -sSL -o opus.tar.gz "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
tar -xzf opus.tar.gz
SRC="$WORK/opus-${OPUS_VERSION}"

build() { # $1 = sdk (iphoneos|iphonesimulator), $2 = archs, $3 = out dir
  local sdk="$1" archs="$2" dir="$3"
  cmake -S "$SRC" -B "$dir" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_BUILD_TESTING=OFF -DOPUS_DEEP_PLC=ON -DOPUS_DRED=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$dir" --config Release >/dev/null
  # Compile the shim against the same SDK and fold it into the static library.
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local objs=()
  for arch in $archs; do
    xcrun --sdk "$sdk" clang -c -arch "$arch" -isysroot "$sysroot" -mios-version-min=26.0 \
      -I "$SRC/include" -I "$SHIM" "$SHIM/sotto_opus_shim.c" -o "$dir/shim-$arch.o"
    objs+=("$dir/shim-$arch.o")
  done
  local lib; lib="$(find "$dir" -name 'libopus.a' -path '*Release*' | head -1)"
  xcrun libtool -static -o "$dir/libopus-sotto.a" "$lib" "${objs[@]}"
  mkdir -p "$dir/include/opus"
  cp "$SRC/include/"*.h "$dir/include/opus/"
  cp "$SHIM/sotto_opus_shim.h" "$dir/include/"
  cp "$SHIM/module.modulemap" "$dir/include/"
}

build iphoneos "arm64" "$WORK/ios"
build iphonesimulator "arm64" "$WORK/sim"

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/ios/libopus-sotto.a" -headers "$WORK/ios/include" \
  -library "$WORK/sim/libopus-sotto.a" -headers "$WORK/sim/include" \
  -output "$OUT"
echo "Built $OUT (opus $OPUS_VERSION, Deep PLC on, DRED off)"
