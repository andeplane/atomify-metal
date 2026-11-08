# Sourced by build-host.sh and check-examples.sh. host_openmp <build-dir>
# sets openmp_cmake (arguments for configuring LAMMPS) and openmp_link
# (flags for linking against liblammps.a) for this machine. Linux uses the
# compiler's OpenMP; macOS builds LLVM's libomp (build-libomp.sh), since
# Apple's clang has none. Both stay empty with ATOMIFY_OPENMP=OFF.
host_openmp() {
  openmp_cmake=(); openmp_link=()
  [ "${ATOMIFY_OPENMP:-ON}" = OFF ] && return
  if [ "$(uname)" = Darwin ]; then
    local omp="$here/build/libomp/host"
    "$here/build-libomp.sh" "$omp/build" "$omp/install"
    local flags="-Xclang -fopenmp -I$omp/install/include"
    openmp_cmake=(-D "OpenMP_C_FLAGS=$flags" -D "OpenMP_CXX_FLAGS=$flags"
                  -D OpenMP_C_LIB_NAMES=omp -D OpenMP_CXX_LIB_NAMES=omp
                  -D "OpenMP_omp_LIBRARY=$omp/install/lib/libomp.a")
    openmp_link=("$omp/install/lib/libomp.a")
  else
    openmp_link=(-fopenmp)
  fi
}
