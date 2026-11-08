#!/bin/bash
# Builds LAMMPS plus the Atomify bridge as Packages/AtomifyKit/Frameworks/CLammps.xcframework
# with three static slices: visionOS device, visionOS Simulator and macOS
# (the macOS slice lets `swift test` exercise the real engine on a Mac).
# Needs Xcode with the visionOS platform and CMake >= 3.28. Takes a while.
#   LAMMPS/build-xcframework.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="$here/build"
source_dir="$build/lammps"
jobs="$(sysctl -n hw.ncpu)"
visionos_target=26.0
macos_target=15.0

python3 "$here/prepare_lammps.py" "$source_dir"

build_slice() {
  local name="$1"; shift
  cmake -S "$source_dir/cmake" -B "$build/$name" -C "$here/atomify-preset.cmake" \
    -D CMAKE_BUILD_TYPE=Release -D CMAKE_OSX_ARCHITECTURES=arm64 \
    -D CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY "$@"
  cmake --build "$build/$name" --target lammps -j "$jobs"
  # One archive per slice, including any helper libraries LAMMPS built.
  find "$build/$name" -maxdepth 2 -name '*.a' ! -name libCLammps.a -print0 \
    | xargs -0 libtool -static -no_warning_for_no_symbols -o "$build/$name/libCLammps.a"
}

build_slice xros -D CMAKE_SYSTEM_NAME=visionOS -D CMAKE_OSX_SYSROOT=xros \
  -D CMAKE_OSX_DEPLOYMENT_TARGET="$visionos_target"
build_slice xrsimulator -D CMAKE_SYSTEM_NAME=visionOS -D CMAKE_OSX_SYSROOT=xrsimulator \
  -D CMAKE_OSX_DEPLOYMENT_TARGET="$visionos_target"
build_slice macos -D CMAKE_OSX_SYSROOT=macosx -D CMAKE_OSX_DEPLOYMENT_TARGET="$macos_target"

output="$here/../Packages/AtomifyKit/Frameworks/CLammps.xcframework"
rm -rf "$output"
mkdir -p "$(dirname "$output")"
xcodebuild -create-xcframework \
  -library "$build/xros/libCLammps.a" -headers "$here/bridge/include" \
  -library "$build/xrsimulator/libCLammps.a" -headers "$here/bridge/include" \
  -library "$build/macos/libCLammps.a" -headers "$here/bridge/include" \
  -output "$output"
echo "Built $output"
