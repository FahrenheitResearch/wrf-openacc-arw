# GPU Port Status

## Scope

This document is the public checkpoint for the current WRF-ARW GPU-port tree. It is intentionally narrow: it describes what is validated now, what is still experimental, and what remains unfinished.

## Current Validated Stack

The checked-in reference cases currently validate this active stack:

- dynamics: `dyn_em`
- microphysics: `mp_physics = 6` (`WSM6`)
- surface layer: `sf_sfclay_physics = 1`
- land surface: `sf_surface_physics = 1`
- PBL: `bl_pbl_physics = 1` (`YSU`)
- radiation: `ra_lw_physics = 0`, `ra_sw_physics = 0`
- cumulus: `cu_physics = 0`

That is the current public baseline. Broader physics coverage exists only in partial or experimental form.

## Build Lanes

- `build-openacc-nvhpc/main/wrf`
  Default NVHPC/OpenACC single-domain control lane.
- `build-openacc-nvhpc-hostfences-exp/main/wrf`
  Experimental ownership lane for more aggressive `small_step_em` and scalar cuts.
- `build-openacc-nvhpc-mpi/main/wrf`
  NVHPC+MPI+OpenACC nested validation lane.

## Latest Validated Results

| Lane | Case | Result |
|---|---|---|
| Default NVHPC/OpenACC | `20260412T0151Z-default` | `exit 0`, `6 wrfout`, `113 s` |
| Experimental host-fence NVHPC/OpenACC | `20260412T1620Z-hostfences-restore-calccoef` | `exit 0`, `6 wrfout`, `159 s` |
| Nested MPI/OpenACC short smoke | `nested-smoke-2021-mpi-short-advancew-scratch` | `SUCCESS COMPLETE WRF` through `2021-12-30_17:05:00` with invariant checks passing |
| Nested MPI/OpenACC repeated 1-hour loop | `overnight-20260412` | six local repeated one-hour nested runs completed through `2021-12-30_18:00:00` |

Derived single-domain checkpoint numbers for the current short control:

- wall time per simulated minute: about `22.6 s`
- real-time factor: about `2.65x`

## What Is Working

- NVHPC/OpenACC builds and runs on the active single-domain stack.
- NVHPC+MPI+OpenACC builds and runs on the nested smoke path.
- The runtime residency layer in [module_gpu_runtime.F](../frame/module_gpu_runtime.F) is real, not a stub.
- Boundary input/output host preparation is wired through [module_io_domain.F](../share/module_io_domain.F) and mediation hooks.
- The active surface/PBL stack has materially less wrapper and staging overhead than it started with.
- WSM6 remains the strongest GPU physics foothold.
- The scalar path has real structural work in [module_em.F](../dyn_em/module_em.F) and [module_advect_em.F](../dyn_em/module_advect_em.F), including the current positive-definite `h5/v3` experimental seam.

## What Is Experimental

- The `WRF_OPENACC_EXPERIMENTAL_SMALLSTEP_*` / host-fence lane is for ownership experiments, not production timing.
- The newest `advect_scalar_pd` ownership cuts and the retained `advance_w` scratch hoist are kept because they are architecturally correct, not because every intermediate experiment was a speed win.
- Nested exchange ownership below mediation is still not fully GPU-owned.

## Current Blunt Estimates

- full literal WRF GPU port: about `15%`
- useful GPU-first active 3 km stack: about `55%`
- production-capable nested `25 km -> 9 km -> 3 km` path: about `30%`

## Immediate Next Technical Targets

- finish the next coarse nonhydro `small_step_em` / `solve_em` ownership cut around the post-`sumflux` boundary-update, second-`calc_p_rho`, and `p`-halo segment
- keep deeper caller-side ownership work above the `advect_scalar_pd` seam where it feeds the active positive-definite moisture path
- narrow nested host staging further and eventually push below mediation into `RSL_LITE`
- widen validated physics coverage beyond the current active stack only after the core small-step ownership path is less hybrid

## Deeper Report

For the full technical segment report, use [2026-04-11-segment-report.md](../gpu-port-checkpoints/2026-04-11-segment-report.md).
