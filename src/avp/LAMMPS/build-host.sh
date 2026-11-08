#!/bin/bash
# Builds LAMMPS with the Atomify bridge for this machine (Linux or macOS) and
# runs the bridge tests. No Apple SDK needed; this checks the C++ side.
#   LAMMPS/build-host.sh [build-dir]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${1:-$here/build/host}"
source_dir="$here/build/lammps"
python3 "$here/prepare_lammps.py" "$source_dir"
cmake -S "$source_dir/cmake" -B "$build" -G Ninja -C "$here/atomify-preset.cmake" -D CMAKE_BUILD_TYPE=Release
cmake --build "$build" --target lammps
c++ -std=c++17 -O1 -g -I"$here/bridge/include" "$here/bridge/tests/bridge_test.cpp" \
  "$build/liblammps.a" -lpthread -o "$build/bridge_test"
cd "$here/bridge/tests" && "$build/bridge_test"
