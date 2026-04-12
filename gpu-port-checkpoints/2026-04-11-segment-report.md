# WRF-ARW GPU Port Segment Report

Created: 2026-04-11 PDT
Scope: Consolidated technical segment report for the current GPU-port campaign through the published public checkpoint.

Public-repo note: this report is committed as a checkpoint document, and the corresponding public snapshot is published at `https://github.com/FahrenheitResearch/wrf-openacc-arw`. Many raw run directories referenced here are local validation artifacts and are intentionally not part of the public repository contents.

## 2026-04-12 Addendum

The repository moved materially past the original public checkpoint after this report was first written.

- The retained experimental host-fence lane is now in the `159 s` class, not the older `376 s` class.
- The retained default short control remains in the `113-114 s` class.
- The retained small-step line includes the `advance_w` caller-scratch hoist and the corrected host-side `calc_coef_w` path in `solve_em.F`.
- A missing `calc_coef_w` call in the compiled host-fence path was found by checking the actual preprocessed build and then fixed.
- A device-side `calc_coef_w` ownership attempt was tested and rejected because it regressed to `176 s`; the active branch remains on the faster corrected host-side coefficient build.
- The nested harness now includes [validate_wrf_run_invariants.py](../tools/validate_wrf_run_invariants.py), so the short nested smoke proves more than simple survival.

The main blocker description is also sharper than in the original text below: the current next coarse ownership cut is the nonhydro `small_step_em` / `solve_em` segment around post-`sumflux` boundary updates, the second `calc_p_rho`, and the `p`-halo exchange.

## Abstract

This segment moved the WRF-ARW GPU port from isolated GPU-enabled kernels toward phase-level device residency. The largest durable changes were: a real runtime residency layer in `frame/module_gpu_runtime.F`; materially reduced wrapper/staging overhead in the active 3 km physics stack; a repeatable NVHPC+MPI+OpenACC nested lane; a functioning remote two-node validation workflow; and new scalar/advection restructuring in `dyn_em/module_em.F` and `dyn_em/module_advect_em.F`, including the current positive-definite `h5/v3` degraded-edge-band seam.

The strongest validated performance result for the older local short single-domain stack remains `run_gpu_batch59_nvhpc_fullactive_stack` at `real 154.62 s`, down from the old control `run_gpu_batch53_nvhpc_muts_physbc` at `real 207.64 s`, a `25.54%` wall-time improvement. The final remote public-checkpoint validations for this segment finished at `128 s` on the default NVHPC/OpenACC lane and `376 s` on the experimental host-fence lane. Since that checkpoint, the retained branch improved to about `113-114 s` on the default lane and `159 s` on the corrected host-fence lane. Nested MPI/OpenACC validation progressed from short smokes to a completed one-hour, two-domain run through `2021-12-30_18:00:00`, and the final short nested validation for the published checkpoint passed cleanly through `2021-12-30_17:05:00`.

This is not a complete GPU WRF. The model is still architecturally hybrid: selected dynamics, surface/PBL, microphysics, and radiation fields can remain resident, but the timestep still crosses back to host in major nonhydro/scalar and I/O/nesting phases. The dominant remaining architecture problem is therefore a genuinely GPU-owned nonhydro/scalar evolution path rather than isolated loop offload. The segment now ends at a real public checkpoint rather than with runs still pending.

## Executive Status

### Current blunt estimates

- Full literal WRF GPU port: about `15%`
- Useful GPU-first active 3 km stack: about `55%`
- Production-capable nested `25 km -> 9 km -> 3 km` path: about `30%`

### What changed materially in this segment

- The residency layer became real instead of being mostly scaffolding.
- The active Noah/YSU/SFCLAY/WSM6 stack was reduced in wrapper and staging overhead.
- A bounded radiation seam was added.
- NVHPC+MPI+OpenACC became a repeatable build and validation lane.
- Nested GPU validation moved from speculative to real.
- The scalar path was simplified around one-member execution and the first internal `advect_scalar_pd` seam was created.
- Remote validation on two RTX 5090 nodes became operational and reusable.

### What is still fundamentally unfinished

- A coarse GPU-owned `small_step_em` / `solve_em` region
- Deeper caller-side scratch ownership above scalar/advection seams
- Nest exchange ownership below mediation and into `RSL_LITE`
- Broader physics coverage beyond the active stack
- Restart/history/nesting ownership as a full end-to-end system

## Initial Conditions

At the start of this work, the repository already had meaningful GPU-port effort:

- build/runtime GPU plumbing existed
- real-data GPU runs existed
- parts of `dyn_em` were offloaded
- WSM6 work existed
- NVHPC/OpenACC materially outperformed GNU/OpenACC

But the codebase still had clear structural deficits:

- `module_gpu_runtime.F` was mostly a hook shell
- `small_step_em` remained the dominant blocker
- surface/PBL/Noah paths were incomplete
- persistent timestep-level device residency was not finished
- halo/exchange, nesting, restart, and much broader physics ownership remained incomplete

## Methodology

The work in this segment was organized around three simultaneous lanes:

1. A fast default NVHPC control lane for single-domain regression and timing.
2. An aggressive experimental NVHPC lane for GPU-ownership cuts that were not yet fit for default.
3. A local nested MPI/OpenACC lane used as an architecture guardrail rather than a separate optimization project.

Parallel subagents were used repeatedly to reduce analysis latency on:

- dyn_em ownership seams
- Noah/SFCLAY/YSU field manifolds
- nesting and mediation boundaries
- `advect_scalar_pd` seam selection
- performance triage when regressions appeared

Two remote RTX 5090 nodes were converted from ad hoc machines into repeatable validation workers using:

- [package_wrf_runtime_bundle.sh](../tools/remote/package_wrf_runtime_bundle.sh)
- [deploy_wrf_runtime_bundle.sh](../tools/remote/deploy_wrf_runtime_bundle.sh)
- [start_wrf_worker.sh](../tools/remote/start_wrf_worker.sh)
- [check_wrf_worker.sh](../tools/remote/check_wrf_worker.sh)
- [refresh_wrf_worker.sh](../tools/remote/refresh_wrf_worker.sh)
- [stop_wrf_worker.sh](../tools/remote/stop_wrf_worker.sh)
- [status_wrf_workers.sh](../tools/remote/status_wrf_workers.sh)
- [cycle_wrf_workers.sh](../tools/remote/cycle_wrf_workers.sh)
- [harvest_wrf_runs.sh](../tools/remote/harvest_wrf_runs.sh)
- [presign_r2_url.py](../tools/remote/presign_r2_url.py)

## Architecture Findings

### 1. Residency and ownership were the main problem, not missing pragmas

The biggest early technical conclusion was that bulk directive activation was not the right first move. A large fraction of the code needed explicit ownership and synchronization boundaries more than additional loop directives. This led to real runtime work in [module_gpu_runtime.F](../frame/module_gpu_runtime.F) instead of a repository-wide `!!$acc -> !$acc` sweep.

### 2. `small_step_em` remains the dominant dynamics blocker

That conclusion held throughout the segment. The experimental `WRF_OPENACC_EXPERIMENTAL_SMALLSTEP_*` lanes were useful, but narrow boundary-kernel experiments repeatedly showed that tiny device tails were often a bad local minimum. The productive direction remained coarse-grained ownership, not micro-fence offload.

### 3. The active scalar path is positive-definite scalar advection

The active stack uses:

- `moist_adv_opt = 1`
- `scalar_adv_opt = 1`
- `h_sca_adv_order = 5`
- `v_sca_adv_order = 3`

This made [advect_scalar_pd](../dyn_em/module_advect_em.F) the right next scalar frontier rather than trying to port every scalar mode at once.

### 4. The first safe `advect_scalar_pd` seam is not the limiter itself

Research on the positive-definite limiter tail found that the in-place limiter rescales shared face fluxes and therefore races if naively parallelized. The first safe cut is the divergence-only part of the tail after the limiter, not the limiter rescale loop itself.

### 5. Nested validation is now a forcing function, not a guess

The nested MPI/OpenACC lane went from “should work in principle” to an actual repeated validation path. This changed nesting from a theoretical requirement into a concrete source of evidence about what ownership boundaries are still wrong.

## Major Implemented Work

### Build and runtime infrastructure

- [CMakeLists.txt](../CMakeLists.txt)
- [main/CMakeLists.txt](../main/CMakeLists.txt)
- [external/io_int/CMakeLists.txt](../external/io_int/CMakeLists.txt)
- [external/io_netcdf/CMakeLists.txt](../external/io_netcdf/CMakeLists.txt)
- [tools/configure_nvhpc_mpi_openacc.sh](../tools/configure_nvhpc_mpi_openacc.sh)

These changes normalized OpenACC compile/link behavior, fixed earlier unresolved accelerator-link issues, and established a scripted NVHPC+MPI+OpenACC lane.

### Runtime residency and I/O boundaries

- [module_gpu_runtime.F](../frame/module_gpu_runtime.F)
- [module_io_domain.F](../share/module_io_domain.F)
- [mediation_integrate.F](../share/mediation_integrate.F)
- [mediation_interp_domain.F](../share/mediation_interp_domain.F)
- [mediation_force_domain.F](../share/mediation_force_domain.F)
- [mediation_feedback_domain.F](../share/mediation_feedback_domain.F)

The residency layer now supports real field synchronization, boundary input/output host preparation, stream-aware scalar synchronization, narrower nesting prep by phase, and more credible per-domain behavior than the original shell.

### Dynamics and small-step experimental ownership

- [solve_em.F](../dyn_em/solve_em.F)
- [module_small_step_em.F](../dyn_em/module_small_step_em.F)
- [module_big_step_utilities_em.F](../dyn_em/module_big_step_utilities_em.F)
- [module_bc.F](../share/module_bc.F)

This segment carried several experimental ownership cuts in and out of the host-fence lane. Many narrow tail experiments were intentionally measured and then discarded or narrowed when they proved to be structurally wrong. That negative information was useful: it kept the port from locking into many tiny device-side boundary kernels with terrible launch economics.

### Scalar and advection path

- [module_em.F](../dyn_em/module_em.F)
- [module_advect_em.F](../dyn_em/module_advect_em.F)

These are the newest important structural changes.

Work landed here includes:

- one-member fast paths in `q_diabatic_add`, `q_diabatic_subtr`, `rk_update_scalar`, and `rk_update_scalar_pd`
- one-member dispatch inside `rk_scalar_tend`
- elimination of unnecessary `h_tendency/z_tendency` zeroing when `tenddec = .false.`
- creation of a first internal `advect_scalar_pd_limiter_tail` seam
- first experimental divergence-only device cut on that seam, isolated to the host-fence build

### Surface, PBL, Noah, and diagnostics

- [module_surface_driver.F](../phys/module_surface_driver.F)
- [module_pbl_driver.F](../phys/module_pbl_driver.F)
- [module_bl_ysu.F](../phys/module_bl_ysu.F)
- [module_sf_sfclay.F](../phys/module_sf_sfclay.F)
- [module_sf_sfclayrev.F](../phys/module_sf_sfclayrev.F)
- [sf_sfclayrev.F90](../phys/physics_mmm/sf_sfclayrev.F90)
- [module_sf_noahdrv.F](../phys/module_sf_noahdrv.F)
- [module_sf_noahlsm.F](../phys/module_sf_noahlsm.F)
- [module_sf_sfcdiags.F](../phys/module_sf_sfcdiags.F)

This stack saw some of the most durable progress in the segment:

- repeated staging cuts in surface/PBL handoff
- removal of dead or redundant temporary passes
- first plain-land Noah batch seam and then a real two-file batch ABI
- continued tightening of the active `ICE == 0` plain-land path
- a real fix for the SFCLAYREV stable/unstable lookup crash site

### Microphysics and radiation

- [module_mp_wsm6.F](../phys/module_mp_wsm6.F)
- [mp_wsm6.F90](../phys/physics_mmm/mp_wsm6.F90)
- [mp_wsm6_effectRad.F90](../phys/physics_mmm/mp_wsm6_effectRad.F90)
- [module_radiation_driver.F](../phys/module_radiation_driver.F)

WSM6 remains the strongest GPU physics foothold. Wrapper overhead was reduced, the direct path was cleaned up, effect-radii was tightened, and an early bounded radiation seam was added around `cal_cldfra1`.

### MPI and nesting support changes

- [module_firebrand_spotting.F](../phys/module_firebrand_spotting.F)
- [module_firebrand_spotting_mpi.F](../phys/module_firebrand_spotting_mpi.F)

These changes removed a concrete NVHPC+MPI blocker and helped the MPI/OpenACC lane build cleanly.

## Validation Summary

### Single-domain short fast-lane milestones

| Run | Result | Notes |
|---|---:|---|
| `run_gpu_batch53_nvhpc_muts_physbc` | `207.64 s` | old short control |
| `run_gpu_batch59_nvhpc_fullactive_stack` | `154.62 s` | best earlier fast validated result |
| `run_gpu_batch61_nvhpc_outputsync_repeat` | `154.99 s` | fast lane revalidation |
| `run_gpu_batch65_nvhpc_postwsm6revert` | `154.95 s` | restored fast control after WSM6 regression |
| `20260411T0534Z-default` | `392 s` | validated remote short default (`00:06:32`) |
| `20260411T0559Z-default` | `373 s` | validated remote short default on current scalar-cleanup binary (`00:06:13`) |
| `20260411T1723Z-default` | `128 s` | final remote short default at the public checkpoint (`00:02:08`) |
| `20260411T1723Z-hostfences` | `376 s` | final remote short experimental host-fence validation (`00:06:16`) |

### Normalized single-domain metrics

For the single-domain runs in this segment, the key normalized quantities are:

- `speedup = T_old / T_new`
- `percent_improvement = (T_old - T_new) / T_old`
- `seconds_per_simulated_minute = T_wall / simulated_minutes`
- `real_time_factor = simulated_seconds / T_wall`

| Run | Simulated minutes | Wall time | Sec / sim min | Real-time factor | Relative to old control |
|---|---:|---:|---:|---:|---:|
| `run_gpu_batch53_nvhpc_muts_physbc` | 5 | `207.64 s` | `41.53` | `1.44x` | baseline |
| `run_gpu_batch59_nvhpc_fullactive_stack` | 5 | `154.62 s` | `30.92` | `1.94x` | `1.34x` speedup, `25.53%` faster |
| `run_gpu_batch65_nvhpc_postwsm6revert` | 5 | `154.95 s` | `30.99` | `1.94x` | `1.34x` speedup, `25.37%` faster |
| `20260411T0534Z-default` | 15 | `392 s` | `26.13` | `2.30x` | remote default reference |
| `20260411T0559Z-default` | 15 | `373 s` | `24.87` | `2.41x` | `1.05x` speedup, `4.85%` faster than prior remote default |
| `20260411T1723Z-default` | 5 | `128 s` | `25.60` | `2.34x` | final remote public-checkpoint control |
| `20260411T1723Z-hostfences` | 5 | `376 s` | `75.20` | `0.80x` | correctness-valid experimental ownership lane |

The validated short fast lane therefore improved from `41.53` wall seconds per simulated minute on the old control to `30.92` on the best earlier local short case, while the final remote default public-checkpoint lane ran at `25.60` wall seconds per simulated minute.

### Single-domain longer fast-lane validation

| Run | Result | Notes |
|---|---:|---|
| `20260411T0542Z-defaultlong` | `786 s` | validated long default remote run (`00:13:06`) |

### Nested MPI/OpenACC validation

| Case | Result | Notes |
|---|---:|---|
| [nested-smoke-2021-mpi-short-tight](../gpu-port-checkpoints/nested-smoke-2021-mpi-short-tight) | pass to `17:05` | validated tighter interp/force nesting path |
| [nested-smoke-2021-mpi-short-feedback](../gpu-port-checkpoints/nested-smoke-2021-mpi-short-feedback) | pass to `17:05` | validated feedback-specific narrowing |
| `nested-smoke-2021-mpi-short-pd-h5-edges` | pass to `17:05` | validated final PD `h5/v3` degraded-edge-band checkpoint |
| [nested-smoke-2021-mpi](../gpu-port-checkpoints/nested-smoke-2021-mpi) | pass to `18:00` | completed one-hour nested MPI/OpenACC run |

Concrete evidence for the one-hour nested run:

- [rsl.error.0000](../gpu-port-checkpoints/nested-smoke-2021-mpi/rsl.error.0000) shows domain 1 and domain 2 timing lines through `2021-12-30_18:00:00`
- [rsl.error.0000](../gpu-port-checkpoints/nested-smoke-2021-mpi/rsl.error.0000) ends with `SUCCESS COMPLETE WRF`
- output files exist for both domains at `17:00` and `18:00`

In the recovered end-of-run window from `17:59:00` to `18:00:00`, domain 2 timings fall in a `2.73-3.74 s` band with mean `3.40 s` per 4 s nest step, while domain 1 timings fall in a `45.53-47.90 s` band with mean `46.49 s` per 12 s parent step. On a per-line basis that is a late-run `d01/d02` ratio of `13.67x`. Normalized to equal simulated time, domain 2 covers the same 12 s interval in three steps with an aggregate mean cost of about `10.20 s`, so domain 1 still dominates the nested wall-clock budget by about `4.56x` over an equal model-time interval.

### Experimental advection status

The current positive-definite scalar advection checkpoint is now stronger than “provisional.” The `h5/v3` degraded-edge-band seam in `advect_scalar_pd` rebuilt cleanly in all NVHPC lanes, held the default single-domain lane at `128 s`, completed the experimental host-fence lane at `376 s`, and passed the nested MPI/OpenACC short smoke through `2021-12-30_17:05:00`. It should still be treated as an ownership/correctness step rather than a performance win.

## Plot and Evidence Artifacts

- [nested_runtime_progress.png](../gpu-port-checkpoints/plots/2026-04-10-nested-smoke/nested_runtime_progress.png)
- [nested_snapshot_fields.png](../gpu-port-checkpoints/plots/2026-04-10-nested-smoke/nested_snapshot_fields.png)
- [2026-04-10-0046-pdt.md](../gpu-port-checkpoints/2026-04-10-0046-pdt.md)

## Research Conclusions

### Durable positive conclusions

1. The active 3 km stack is materially faster than the old control and is no longer just a demonstration. The best validated short case improved from `41.53` to `30.92` wall seconds per simulated minute, and the refreshed remote default lane improved from `26.13` to `24.87`.
2. The runtime ownership layer was worth building; it was the correct architectural move because the limiting cost came from phase boundaries where mutation authority returned to host code, not from raw directive count alone.
3. The best subsystem strategy is still selective narrowing around one supported stack, not diffuse scheme-by-scheme offload.
4. Noah and the surface/PBL stack were high-value targets and paid off more than tiny dynamics tail kernels.
5. Nested MPI/OpenACC validation is now credible enough to function as a real architecture gate: the completed one-hour run provides a measured domain-1/domain-2 timing split instead of a simple pass/fail claim.

### Negative conclusions that were still useful

1. Tiny boundary-tail kernels in `small_step_em` were often the wrong direction.
2. The wrapper-side WSM6 theta-restore loop was a bad accelerator insertion in the still-hybrid path.
3. A naive GPU limiter for `advect_scalar_pd` is unsafe because of shared-face races in the face-flux rescaling loop; the first safe GPU cut is the post-limiter divergence region, not the limiter itself.
4. Caller-local scratch ownership above scalar/advection remains a serious missing layer.

## Published Checkpoint Scope

The public checkpoint that closed this segment was published at:

- `https://github.com/FahrenheitResearch/wrf-openacc-arw`
- public snapshot commit: `063e077`

The curated publish scope for that snapshot was:

- `53` tracked files changed
- `8384` insertions
- `1391` deletions

The two biggest current hotspots are:

- [module_gpu_runtime.F](../frame/module_gpu_runtime.F)
- [module_em.F](../dyn_em/module_em.F)
- [module_advect_em.F](../dyn_em/module_advect_em.F)
- [solve_em.F](../dyn_em/solve_em.F)
- [module_bc.F](../share/module_bc.F)
- [module_sf_noahdrv.F](../phys/module_sf_noahdrv.F)
- [module_sf_noahlsm.F](../phys/module_sf_noahlsm.F)

## Overnight-Run Closeout

The three attempted overnight runs did not provide valid long-horizon evidence because they were configured past the available lateral boundary forcing horizon and all stopped at the same `wrfbdy_d01` limit. That failure mode is now guarded in:

- [validate_wrf_forcing_horizon.py](../tools/validate_wrf_forcing_horizon.py)
- [run_nested_smoke_2021_mpi.sh](../gpu-port-checkpoints/run_nested_smoke_2021_mpi.sh)
- [package_wrf_runtime_bundle.sh](../tools/remote/package_wrf_runtime_bundle.sh)

That forcing-horizon fix is part of the final published checkpoint.

## Immediate Next Steps After This Checkpoint

1. Widen caller-side ownership one level up from the current `advect_scalar_pd` seam in `rk_scalar_tend_member` around:
   - `wwE`
   - `advect_tend`
   - `h_tendency`
   - `z_tendency`
2. Return to a coarse `small_step_em` / `solve_em` ownership cut instead of more micro-fence work.
3. Keep nesting work as a guardrail, but continue to bias effort toward core GPU ownership rather than over-investing in comm plumbing too early.
4. Use the published `wrf-openacc-arw` repo as the canonical collaboration point for the next session.

## Bottom Line

This segment produced real code, real builds, real runtime evidence, and real architectural narrowing.

The strongest outcomes were:

- a much more credible runtime ownership layer
- a materially stronger active physics stack
- a functioning nested MPI/OpenACC validation path
- a cleaner scalar evolution path with the first bounded `advect_scalar_pd` seam
- a repeatable remote validation workflow

The segment did **not** finish the GPU port. But it ended in a much better place than it started, and it now closes at a real public checkpoint with validated default, experimental, and nested smoke paths rather than at an internal “runs still pending” pause.
