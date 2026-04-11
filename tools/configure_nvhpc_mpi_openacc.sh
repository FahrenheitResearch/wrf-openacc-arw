#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  configure_nvhpc_mpi_openacc.sh [configure|build|all] [build_dir]

Modes:
  configure  Configure the NVHPC+MPI+OpenACC build tree only.
  build      Build the configured tree only.
  all        Configure, then build. Default.

Defaults:
  build_dir = build-openacc-nvhpc-mpi

Environment overrides:
  WRF_REPO_ROOT            repository root (default: parent of this script)
  WRF_BUILD_DIR            build directory override
  NVHPC_BIN_DIR            NVHPC compiler bin dir
  WRF_MPI_ROOT             MPI install root
  WRF_BUILD_TARGETS        space-separated targets to build (default: "real wrf")
  WRF_BUILD_JOBS           parallel build jobs (default: 8)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=${WRF_REPO_ROOT:-$(cd "$script_dir/.." && pwd)}

mode=${1:-all}
case "$mode" in
  configure|build|all) ;;
  *)
    echo "invalid mode: $mode" >&2
    usage >&2
    exit 1
    ;;
esac

build_dir=${2:-"${WRF_BUILD_DIR:-$repo_root/build-openacc-nvhpc-mpi}"}
nvhpc_bin_dir=${NVHPC_BIN_DIR:-/opt/nvidia/hpc_sdk/Linux_x86_64/26.3/compilers/bin}
mpi_root=${WRF_MPI_ROOT:-/home/drew/WRF_BUILD/LIBRARIES/mpich}
build_targets=${WRF_BUILD_TARGETS:-"real wrf"}
build_jobs=${WRF_BUILD_JOBS:-8}

nvc_bin="$nvhpc_bin_dir/nvc"
nvcxx_bin="$nvhpc_bin_dir/nvc++"
nvfortran_bin="$nvhpc_bin_dir/nvfortran"

for bin in "$nvc_bin" "$nvcxx_bin" "$nvfortran_bin"; do
  [[ -x "$bin" ]] || { echo "missing compiler: $bin" >&2; exit 1; }
done

for lib in "$mpi_root/lib/libmpi.so" "$mpi_root/lib/libmpifort.so"; do
  [[ -f "$lib" ]] || { echo "missing MPI library: $lib" >&2; exit 1; }
done

[[ -d "$mpi_root/include" ]] || { echo "missing MPI include dir: $mpi_root/include" >&2; exit 1; }

configure_tree() {
  cmake -S "$repo_root" -B "$build_dir" \
    -DCMAKE_C_COMPILER="$nvc_bin" \
    -DCMAKE_CXX_COMPILER="$nvcxx_bin" \
    -DCMAKE_Fortran_COMPILER="$nvfortran_bin" \
    -DUSE_OPENACC=ON \
    -DUSE_MPI=ON \
    -DMPI_ASSUME_NO_BUILTIN_MPI=TRUE \
    -DMPI_SKIP_COMPILER_WRAPPER=TRUE \
    -DMPI_SKIP_GUESSING=TRUE \
    -DMPI_C_LIB_NAMES=mpi \
    -DMPI_mpi_LIBRARY="$mpi_root/lib/libmpi.so" \
    -DMPI_C_HEADER_DIR="$mpi_root/include" \
    -DMPI_Fortran_LIB_NAMES="mpifort;mpi" \
    -DMPI_mpifort_LIBRARY="$mpi_root/lib/libmpifort.so" \
    -DMPI_Fortran_F77_HEADER_DIR="$mpi_root/include"
}

build_tree() {
  local target
  for target in $build_targets; do
    cmake --build "$build_dir" -j "$build_jobs" --target "$target"
  done
}

case "$mode" in
  configure)
    configure_tree
    ;;
  build)
    build_tree
    ;;
  all)
    configure_tree
    build_tree
    ;;
esac
