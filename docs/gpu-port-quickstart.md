# GPU Port Quickstart

## Scope

This quickstart is for the validated NVHPC/OpenACC checkpoint in this tree. It is not a general WRF installation guide.

## Prerequisites

- NVHPC compilers available locally
- for nested MPI/OpenACC: MPICH or equivalent MPI install matching [configure_nvhpc_mpi_openacc.sh](../tools/configure_nvhpc_mpi_openacc.sh)
- NetCDF and the normal WRF build prerequisites already available

## 1. Build The Default NVHPC/OpenACC Lane

If `build-openacc-nvhpc` is not configured yet, configure it with NVHPC and `-DUSE_OPENACC=ON`. Then build:

```bash
cmake --build build-openacc-nvhpc -j 8 --target real wrf
```

Validated binary:

- `build-openacc-nvhpc/main/wrf`

## 2. Run The Reference Single-Domain Case

The current validated control case name is:

- `run_gpu_batch59_nvhpc_fullactive_stack`

That local case directory is not committed because it contains forcing and output artifacts. To rerun the same configuration, use your own `em_real` case directory with the validated physics stack from [GPU Port Status](gpu-port-status.md), place the current binaries into it, then run `wrf` with one OpenMP thread:

```bash
cd /path/to/your/em_real_case
ulimit -s unlimited
OMP_NUM_THREADS=1 ./wrf
```

Current validated short result on this path:

- `20260412T0151Z-default`
- `exit 0`
- `6 wrfout`
- `113 s`

## 3. Build The Nested MPI/OpenACC Lane

Use the checked-in helper:

```bash
./tools/configure_nvhpc_mpi_openacc.sh all
```

Validated binary:

- `build-openacc-nvhpc-mpi/main/wrf`

## 4. Run The Nested MPI/OpenACC Smoke

Use the checked-in wrapper. For a fresh short smoke:

```bash
WRF_WRF_RUN_MINUTES=5 \
WRF_HISTORY_INTERVAL_MINUTES=5 \
./gpu-port-checkpoints/run_nested_smoke_2021_mpi.sh run \
  gpu-port-checkpoints/nested-smoke-2021-mpi-local \
  run_gpu_batch59_nvhpc_fullactive_stack \
  build-openacc-nvhpc-mpi
```

Validated local case names:

- `nested-smoke-2021-mpi-short-advancew-scratch`
- `nested-smoke-2021-mpi`

Those run directories are not committed because they contain forcing, logs, and model output artifacts.

The nested wrapper now also supports a local invariant check via [validate_wrf_run_invariants.py](../tools/validate_wrf_run_invariants.py), so successful completion is no longer just `exit 0`.

## 5. Forcing-Horizon Guard

The tree now fails fast if a requested runtime extends beyond available forcing or boundary data.

Relevant tooling:

- [validate_wrf_forcing_horizon.py](../tools/validate_wrf_forcing_horizon.py)
- [run_nested_smoke_2021_mpi.sh](../gpu-port-checkpoints/run_nested_smoke_2021_mpi.sh)
- [package_wrf_runtime_bundle.sh](../tools/remote/package_wrf_runtime_bundle.sh)

If a case requests more model time than the available `met_em` or `wrfbdy_d01` files cover, packaging now fails before the run starts.

## 6. Remote Worker Loop

The two-node validation loop uses:

- [refresh_wrf_worker.sh](../tools/remote/refresh_wrf_worker.sh)
- [check_wrf_worker.sh](../tools/remote/check_wrf_worker.sh)
- [status_wrf_workers.sh](../tools/remote/status_wrf_workers.sh)

That path is useful for repeated short validation. It is not required for local development.
