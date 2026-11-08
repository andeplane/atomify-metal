# LAMMPS configuration shared by the host test build and the visionOS slices.
# Serial (MPI STUBS), static, no optional image/compression libraries.
set(BUILD_MPI OFF CACHE BOOL "" FORCE)
set(BUILD_OMP OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(BUILD_LAMMPS_GUI OFF CACHE BOOL "" FORCE)
set(WITH_JPEG OFF CACHE BOOL "" FORCE)
set(WITH_PNG OFF CACHE BOOL "" FORCE)
set(WITH_GZIP OFF CACHE BOOL "" FORCE)
set(WITH_FFMPEG OFF CACHE BOOL "" FORCE)
set(FFT KISS CACHE STRING "" FORCE)
set(LAMMPS_SIZES smallbig CACHE STRING "" FORCE)

# Packages the bundled demos need, plus common ones for user scripts.
foreach(pkg MOLECULE MANYBODY KSPACE RIGID GRANULAR MISC CLASS2 EXTRA-MOLECULE
            EXTRA-PAIR EXTRA-FIX EXTRA-COMPUTE REAXFF QEQ MC ASPHERE CG-DNA)
  set(PKG_${pkg} ON CACHE BOOL "" FORCE)
endforeach()
