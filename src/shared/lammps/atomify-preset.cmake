# LAMMPS configuration shared by the host test build and the Apple slices.
# No MPI (STUBS), static, no optional image/compression libraries.
# Threads come from OpenMP and the OPENMP package (/omp styles); the bridge
# turns them on per simulation (atomify_sim_create_threaded). Apple ships no
# OpenMP runtime, so build-xcframework.sh builds LLVM's libomp per slice
# (build-libomp.sh) and passes it in. The environment variable
# ATOMIFY_OPENMP=OFF gives a serial build.
set(BUILD_MPI OFF CACHE BOOL "" FORCE)
set(ATOMIFY_OPENMP ON)
if(DEFINED ENV{ATOMIFY_OPENMP})
  set(ATOMIFY_OPENMP $ENV{ATOMIFY_OPENMP})
endif()
set(BUILD_OMP ${ATOMIFY_OPENMP} CACHE BOOL "" FORCE)
set(PKG_OPENMP ${ATOMIFY_OPENMP} CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(BUILD_LAMMPS_GUI OFF CACHE BOOL "" FORCE)
set(WITH_JPEG OFF CACHE BOOL "" FORCE)
set(WITH_PNG OFF CACHE BOOL "" FORCE)
set(WITH_GZIP OFF CACHE BOOL "" FORCE)
set(WITH_ZLIB OFF CACHE BOOL "" FORCE)    # keeps the library free of a libz dependency
set(WITH_FFMPEG OFF CACHE BOOL "" FORCE)
set(FFT KISS CACHE STRING "" FORCE)
set(LAMMPS_SIZES smallbig CACHE STRING "" FORCE)

# Packages the bundled demos need, plus common ones for user scripts.
foreach(pkg MOLECULE MANYBODY KSPACE RIGID GRANULAR MISC CLASS2 EXTRA-MOLECULE
            EXTRA-PAIR EXTRA-FIX EXTRA-COMPUTE REAXFF QEQ MC ASPHERE CG-DNA SHOCK)
  set(PKG_${pkg} ON CACHE BOOL "" FORCE)
endforeach()
