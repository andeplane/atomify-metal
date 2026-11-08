#!/bin/bash
# Builds LAMMPS with the Atomify bridge for this machine (Linux or macOS) and
# runs the bridge tests. No Apple SDK needed; this checks the C++ side.
#   src/shared/lammps/build-host.sh [build-dir]
# Needs git, CMake >= 3.20, a C++17 compiler and python3. Uses Ninja if
# installed, else Make. JOBS overrides the parallel job count.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${1:-$here/build/host}"
source_dir="$here/build/lammps"
jobs="${JOBS:-$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 4)}"

python3 "$here/prepare_lammps.py" "$source_dir"

generator=()
if [ ! -f "$build/CMakeCache.txt" ]; then
  if command -v ninja >/dev/null 2>&1; then generator=(-G Ninja); else generator=(-G "Unix Makefiles"); fi
fi
cmake -S "$source_dir/cmake" -B "$build" "${generator[@]}" -C "$here/atomify-preset.cmake" \
  -D CMAKE_BUILD_TYPE=Release
cmake --build "$build" --target lammps -j "$jobs"

cxx="${CXX:-c++}"
"$cxx" -std=c++17 -O1 -g -Wall -Wextra -I"$here/bridge/include" "$here/bridge/tests/bridge_test.cpp" \
  "$build/liblammps.a" -lpthread -o "$build/bridge_test"
cd "$build" && ./bridge_test
