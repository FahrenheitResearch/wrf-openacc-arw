## GPU Port Checkpoint

This checkout contains active NVHPC/OpenACC GPU-port work for WRF-ARW.

Current public handoff docs:

- [GPU Port Status](docs/gpu-port-status.md)
- [GPU Port Quickstart](docs/gpu-port-quickstart.md)
- [GPU Port Architecture](docs/gpu-port-architecture.md)
- [GPU Port Known Issues](docs/gpu-port-known-issues.md)
- [2026-04-11 Segment Report](gpu-port-checkpoints/2026-04-11-segment-report.md)

Validated public checkpoint at this session boundary:

- single-domain NVHPC/OpenACC short control: `113-114 s`, `exit 0`, `6 wrfout`
- single-domain experimental host-fence lane: `159 s`, `exit 0`, `6 wrfout`
- nested MPI/OpenACC short smoke: passes invariant checks through `2021-12-30_17:05:00`

Current blocker:

- the main unfinished ownership cut is the nonhydro `small_step_em` / `solve_em` control path around the post-`sumflux` boundary-update, second-`calc_p_rho`, and `p`-halo segment

Validation run directories and forcing/output artifacts are intentionally not committed to this public checkpoint.

### WRF-ARW Modeling System  ###

We request that all new users of WRF please register. This allows us to better determine how to support and develop the model. Please register using this form:[https://www2.mmm.ucar.edu/wrf/users/download/wrf-regist.php](https://www2.mmm.ucar.edu/wrf/users/download/wrf-regist.php).

For an overview of the WRF modeling system, along with information regarding downloads, user support, documentation, publications, and additional resources, please see the WRF Model Users' Web Site: [https://www2.mmm.ucar.edu/wrf/users/](https://www2.mmm.ucar.edu/wrf/users/).
 
Information regarding WRF Model citations (including a DOI) can be found here: [https://www2.mmm.ucar.edu/wrf/users/citing_wrf.html](https://www2.mmm.ucar.edu/wrf/users/citing_wrf.html).

The WRF Model is open-source code in the public domain, and its use is unrestricted. The name "WRF", however, is a registered trademark of the University Corporation for Atmospheric Research. The WRF public domain notice and related information may be found here: [https://www2.mmm.ucar.edu/wrf/users/public.html](https://www2.mmm.ucar.edu/wrf/users/public.html).
