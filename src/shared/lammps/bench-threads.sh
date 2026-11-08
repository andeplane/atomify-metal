#!/bin/bash
# Measures LAMMPS speed with OpenMP threads: runs examples with the host build
# of the bridge once per thread count and prints steps per second and speedup.
#   src/shared/lammps/bench-threads.sh [--threads 1,2,4] [--steps N] [--filter TEXT] [--examples DIR]
# Builds like check-examples.sh. See tools/bench_threads.py.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Builds (if needed) and checks nothing: --filter matching no example exits early.
"$here/check-examples.sh" --filter "no example has this id" >/dev/null 2>&1 || true
exec python3 "$here/tools/bench_threads.py" --binary "$here/build/host/example_check" "$@"
