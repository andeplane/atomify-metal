#!/bin/bash
# Builds LAMMPS plus the Atomify bridge as src/shared/lammps/Frameworks/CLammps.xcframework
# with static slices for macOS, iOS, iOS Simulator, visionOS and visionOS
# Simulator (the macOS slice also lets `swift test` exercise the real engine).
# Needs Xcode with the iOS and visionOS platforms and CMake >= 3.28. Takes a while.
#   src/shared/lammps/build-xcframework.sh
# Environment:
#   SLICES="macos ios ios-simulator visionos visionos-simulator"  slices to build
#   MACOS_ARCHS="arm64;x86_64"  universal macOS slice (default arm64)
#   SIMULATOR_ARCHS="arm64;x86_64"  universal simulator slices (default arm64)
#   JOBS=8  parallel compile jobs (default: all cores)
#   ATOMIFY_OPENMP=OFF  serial LAMMPS without OpenMP threads (default ON)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="$here/build"
source_dir="$build/lammps"
jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
slices="${SLICES:-macos ios ios-simulator visionos visionos-simulator}"
macos_archs="${MACOS_ARCHS:-arm64}"
simulator_archs="${SIMULATOR_ARCHS:-arm64}"
# Keep in step with the platforms in the root Package.swift.
macos_target=15.0
ios_target=18.0
visionos_target=2.0

python3 "$here/prepare_lammps.py" "$source_dir"

build_slice() {
  local name="$1" archs="$2"; shift 2
  local openmp=() runtime=()
  if [ "${ATOMIFY_OPENMP:-ON}" != OFF ]; then
    # LLVM's libomp for this slice, handed to LAMMPS' FindOpenMP.
    local omp="$build/libomp/$name"
    JOBS="$jobs" "$here/build-libomp.sh" "$omp/build" "$omp/install" \
      -D "CMAKE_OSX_ARCHITECTURES=$archs" "$@"
    local flags="-Xclang -fopenmp -I$omp/install/include"
    openmp=(-D "OpenMP_C_FLAGS=$flags" -D "OpenMP_CXX_FLAGS=$flags"
            -D OpenMP_C_LIB_NAMES=omp -D OpenMP_CXX_LIB_NAMES=omp
            -D "OpenMP_omp_LIBRARY=$omp/install/lib/libomp.a"
            # LAMMPS' omp.h check passes the OpenMP flags as link options,
            # which reach ar in these static-library try-compiles and fail.
            # omp.h is in the include path above, so answer the check.
            -D _have_omp_h=TRUE)
    runtime=("$omp/install/lib/libomp.a")
  fi
  cmake -S "$source_dir/cmake" -B "$build/$name" -C "$here/atomify-preset.cmake" \
    -D CMAKE_BUILD_TYPE=Release -D "CMAKE_OSX_ARCHITECTURES=$archs" \
    -D CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY ${openmp[@]+"${openmp[@]}"} "$@"
  cmake --build "$build/$name" --target lammps -j "$jobs"
  # One archive per slice, including any helper libraries LAMMPS built and
  # the OpenMP runtime.
  rm -f "$build/$name/libCLammps.a"
  { find "$build/$name" -maxdepth 2 -name '*.a' ! -name libCLammps.a -print0
    for library in ${runtime[@]+"${runtime[@]}"}; do printf '%s\0' "$library"; done; } \
    | xargs -0 libtool -static -no_warning_for_no_symbols -o "$build/$name/libCLammps.a"
}

arguments=()
for slice in $slices; do
  case "$slice" in
    macos)
      build_slice macos "$macos_archs" -D CMAKE_OSX_SYSROOT=macosx \
        -D CMAKE_OSX_DEPLOYMENT_TARGET="$macos_target" ;;
    ios)
      build_slice ios arm64 -D CMAKE_SYSTEM_NAME=iOS -D CMAKE_OSX_SYSROOT=iphoneos \
        -D CMAKE_OSX_DEPLOYMENT_TARGET="$ios_target" ;;
    ios-simulator)
      build_slice ios-simulator "$simulator_archs" -D CMAKE_SYSTEM_NAME=iOS \
        -D CMAKE_OSX_SYSROOT=iphonesimulator -D CMAKE_OSX_DEPLOYMENT_TARGET="$ios_target" ;;
    visionos)
      build_slice visionos arm64 -D CMAKE_SYSTEM_NAME=visionOS -D CMAKE_OSX_SYSROOT=xros \
        -D CMAKE_OSX_DEPLOYMENT_TARGET="$visionos_target" ;;
    visionos-simulator)
      build_slice visionos-simulator "$simulator_archs" -D CMAKE_SYSTEM_NAME=visionOS \
        -D CMAKE_OSX_SYSROOT=xrsimulator -D CMAKE_OSX_DEPLOYMENT_TARGET="$visionos_target" ;;
    *)
      echo "Unknown slice '$slice'" >&2
      exit 1 ;;
  esac
  arguments+=(-library "$build/$slice/libCLammps.a" -headers "$here/bridge/include")
done

output="$here/Frameworks/CLammps.xcframework"
rm -rf "$output"
mkdir -p "$(dirname "$output")"
xcodebuild -create-xcframework "${arguments[@]}" -output "$output"
echo "Built $output"
