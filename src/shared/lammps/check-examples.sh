#!/bin/bash
# Runs every bundled example with the host build of the bridge (Linux or
# macOS, no Xcode needed) and prints a results table. Builds LAMMPS first if
# build-host.sh has not been run.
#   src/shared/lammps/check-examples.sh [--steps N] [--timeout S] [--filter TEXT] [--jobs N]
#                                       [--examples DIR] [--threads T] [--continue] [--keep]
# Defaults: 100 steps after the first run starts, 120 s per example, all
# examples in src/macos/AtomifyMac/Examples, one at a time. Exits 1 if any
# example failed or timed out. See tools/check_examples.py.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="$here/build/host"

[ -f "$build/liblammps.a" ] || "$here/build-host.sh" "$build"
# Rebuild the library when bridge or LAMMPS sources changed (no-op otherwise).
python3 "$here/prepare_lammps.py" "$here/build/lammps" >/dev/null
cmake --build "$build" --target lammps -j "${JOBS:-$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 4)}" >/dev/null

source "$here/host-openmp.sh"
host_openmp "$build"
binary="$build/example_check"
if [ ! -x "$binary" ] || [ "$here/tools/example_check.cpp" -nt "$binary" ] || [ "$build/liblammps.a" -nt "$binary" ]; then
  "${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -I"$here/bridge/include" "$here/tools/example_check.cpp" \
    "$build/liblammps.a" ${openmp_link[@]+"${openmp_link[@]}"} -lpthread -o "$binary"
fi
exec python3 "$here/tools/check_examples.py" --binary "$binary" "$@"
