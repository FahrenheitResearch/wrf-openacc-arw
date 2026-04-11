# GPU Port Known Issues

## Scope Limits

- This is not a full GPU WRF.
- The validated public stack is narrow: `WSM6 + YSU + SFCLAY + sf_surface_physics=1`, with no radiation and no cumulus in the checked-in reference cases.
- GNU/OpenACC is not the production target. NVHPC/OpenACC is.

## Performance Interpretation

- The default lane is the timing control.
- The experimental host-fence lane is intentionally slower and should not be used as a production performance reference.
- A slower experimental result does not automatically mean a bad change. Some changes are kept because they are the correct ownership seam.

## Nested Smoke Caveats

- The nested MPI/OpenACC smokes are architecture validation, not production-quality forecast cases.
- The short nested smokes can show repeated `v_cfl > 2` warnings on d02 and still complete successfully.
- Completion of a nested smoke means the ownership boundary is plausible, not that the setup is tuned for production.

## Forcing Horizon

- Shortening `wrf` runtime does not mean `real` can use the same shorter horizon.
- `real` still needs forcing that extends at least one `interval_seconds` beyond the start time.
- The current tooling now guards this, but custom scripts must still respect it.

Relevant files:

- [validate_wrf_forcing_horizon.py](../tools/validate_wrf_forcing_horizon.py)
- [run_nested_smoke_2021_mpi.sh](../gpu-port-checkpoints/run_nested_smoke_2021_mpi.sh)
- [package_wrf_runtime_bundle.sh](../tools/remote/package_wrf_runtime_bundle.sh)

## Current Architecture Limits

- `small_step_em` is still the main dynamics blocker.
- Scalar/advection ownership is improved but not finished.
- Nest exchange ownership is still incomplete below mediation.
- Restart/history/output boundaries are better than they were, but not yet the final selective-residency design.

## Repository Hygiene

- The tree currently contains research artifacts, checkpoint directories, and remote-worker tooling alongside source changes.
- Those artifacts are useful for development, but they are not the same thing as a clean source-only release branch.
