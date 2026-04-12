# GPU Port Architecture

## High-Level Model

This tree is no longer a collection of isolated OpenACC loops. The current design direction is phase-level GPU ownership with explicit host/device boundaries.

The important split is:

- default lane: keep the useful single-domain stack fast and stable
- experimental lane: push ownership cuts that are not yet fit for default
- nested MPI lane: use nesting as a correctness guardrail, not as the primary optimization target

## Residency Layer

The core runtime layer lives in:

- [module_gpu_runtime.F](../frame/module_gpu_runtime.F)

It now owns:

- device enter/update/exit hooks
- boundary input/output host preparation
- stream-aware sync helpers
- narrower nesting prep by phase

Related boundaries are wired through:

- [module_io_domain.F](../share/module_io_domain.F)
- [mediation_integrate.F](../share/mediation_integrate.F)
- [mediation_interp_domain.F](../share/mediation_interp_domain.F)
- [mediation_force_domain.F](../share/mediation_force_domain.F)
- [mediation_feedback_domain.F](../share/mediation_feedback_domain.F)

## Default vs Experimental

The public default lane is the reference path:

- single-domain
- NVHPC/OpenACC
- active physics stack only
- used for timing control

The experimental lane is deliberately different:

- enabled by `WRF_OPENACC_EXPERIMENTAL_SMALLSTEP_*` style flags
- used to prove new ownership seams
- allowed to be much slower than default

At the current retained branch, the experimental short run is still slower than default (`159 s` vs `113 s`). That is acceptable because this lane exists to prove ownership first, not to be the production timing reference.

## Current GPU-Owned Seams

Most durable current seams:

- runtime residency and selective host sync
- reduced wrapper/staging cost in the active surface/PBL stack
- WSM6 direct-path cleanup
- first bounded radiation seam
- one-member scalar fast paths in [module_em.F](../dyn_em/module_em.F)
- positive-definite scalar advection restructuring in [module_advect_em.F](../dyn_em/module_advect_em.F)

The latest scalar/advection checkpoint includes:

- caller-side PD ownership in [module_em.F](../dyn_em/module_em.F)
- race-free facewise limiter application in [module_advect_em.F](../dyn_em/module_advect_em.F)
- experimental `h5/v3` horizontal interior and degraded-edge flux ownership in the PD path

## What Is Still Hybrid

The model is still architecturally hybrid.

The biggest remaining ownership problems are:

- coarse `small_step_em` / `solve_em` residency, especially the nonhydro post-`sumflux` boundary-update, second-`calc_p_rho`, and `p`-halo segment
- deeper caller-side scratch ownership above scalar/advection seams
- nesting exchange ownership below mediation and into `RSL_LITE`
- restart/history ownership as a fully selective system
- broader physics coverage beyond the active stack

## Why The Next Work Stays In Core GPU Ownership

Nested MPI/OpenACC now works well enough to act as a guardrail. That means the highest-leverage remaining work is back in the core GPU port:

- `small_step_em`
- `advect_scalar_pd`
- runtime boundaries
- active-stack physics that still forces host churn

That is why the current roadmap is weighted toward the GPU-port goal rather than deep nesting-specific optimization.
