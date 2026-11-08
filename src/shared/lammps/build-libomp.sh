#!/bin/bash
# Builds LLVM's OpenMP runtime (libomp) as a static library for one Apple
# slice. Apple's toolchain compiles OpenMP (-Xclang -fopenmp) but ships no
# runtime, so build-xcframework.sh builds one per slice and folds it into
# libCLammps.a. LLVM's OpenMP runtime is Apache 2.0 with LLVM exceptions.
#   build-libomp.sh <build-dir> <install-dir> [cmake arguments for the slice...]
# Leaves <install-dir>/include/omp.h and <install-dir>/lib/libomp.a.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="$1"; install="$2"; shift 2
version=19.1.7
source_root="$here/build/llvm-openmp-$version"
base="https://github.com/llvm/llvm-project/releases/download/llvmorg-$version"

# The standalone runtime needs openmp/ and LLVM's shared cmake/ side by side.
if [ ! -f "$source_root/openmp/CMakeLists.txt" ]; then
  rm -rf "$source_root" && mkdir -p "$source_root"
  for part in openmp cmake; do
    curl -fsSL "$base/$part-$version.src.tar.xz" | tar -xJ -C "$source_root"
    mv "$source_root/$part-$version.src" "$source_root/$part"
  done
fi

if [ ! -f "$install/lib/libomp.a" ]; then
  cmake -S "$source_root/openmp" -B "$build" -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_INSTALL_PREFIX="$install" -D CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -D LIBOMP_ENABLE_SHARED=OFF -D OPENMP_ENABLE_LIBOMPTARGET=OFF \
    -D LIBOMP_OMPT_SUPPORT=OFF -D OPENMP_ENABLE_OMPT_TOOLS=OFF -D LIBOMP_USE_HWLOC=OFF \
    -D LIBOMP_INSTALL_ALIASES=OFF -D OPENMP_ENABLE_TESTING=OFF "$@"
  cmake --build "$build" --target install -j "${JOBS:-$(sysctl -n hw.ncpu)}"
fi
