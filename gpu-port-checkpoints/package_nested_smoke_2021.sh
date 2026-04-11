#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  package_nested_smoke_2021.sh [output_dir] [source_case_dir] [build_dir]

Packages a minimal 2-domain real-data GPU smoke case using:
  - in-tree 2021 coarse met_em.d01 inputs
  - build-openacc-nvhpc-mpi/main/{real,wrf}
  - input_from_file = .true., .false. so d02 is generated from the parent

Defaults:
  output_dir      = gpu-port-checkpoints/nested-smoke-2021-mpi
  source_case_dir = run_gpu_batch59_nvhpc_fullactive_stack
  build_dir       = build-openacc-nvhpc-mpi
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

out_dir=${1:-"$repo_root/gpu-port-checkpoints/nested-smoke-2021-mpi"}
source_case=${2:-"$repo_root/run_gpu_batch59_nvhpc_fullactive_stack"}
build_dir=${3:-"${WRF_BUILD_DIR:-$repo_root/build-openacc-nvhpc-mpi}"}

real_bin="$build_dir/main/real"
wrf_bin="$build_dir/main/wrf"

required_bins=("$real_bin" "$wrf_bin")
for bin in "${required_bins[@]}"; do
  if [[ ! -x "$bin" ]]; then
    echo "missing executable: $bin" >&2
    exit 1
  fi
done

met_inputs=(
  "$source_case/met_em.d01.2021-12-30_17:00:00.nc"
  "$source_case/met_em.d01.2021-12-30_18:00:00.nc"
)

for f in "${met_inputs[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "missing met_em input: $f" >&2
    exit 1
  fi
done

runtime_files=(
  GENPARM.TBL
  LANDUSE.TBL
  SOILPARM.TBL
  VEGPARM.TBL
  URBPARM.TBL
  URBPARM_LCZ.TBL
  HLC.TBL
  ETAMPNEW_DATA
  ETAMPNEW_DATA.expanded_rain
  RRTMG_LW_DATA
  RRTMG_SW_DATA
  ozone.formatted
  ozone_lat.formatted
  ozone_plev.formatted
  MPTABLE.TBL
  STOCHPERT.TBL
)

mkdir -p "$out_dir"

ln -sfn "$real_bin" "$out_dir/real"
ln -sfn "$wrf_bin" "$out_dir/wrf"

for f in "${runtime_files[@]}"; do
  src="$source_case/$f"
  if [[ ! -e "$src" ]]; then
    echo "missing runtime file in source case: $src" >&2
    exit 1
  fi
  ln -sfn "$src" "$out_dir/$f"
done

cp -f "${met_inputs[@]}" "$out_dir/"

cat >"$out_dir/namelist.wrf.input" <<'EOF'
&time_control
 run_days                = 0,
 run_hours               = 1,
 run_minutes             = 0,
 run_seconds             = 0,
 start_year              = 2021, 2021,
 start_month             = 12,   12,
 start_day               = 30,   30,
 start_hour              = 17,   17,
 start_minute            = 00,   00,
 start_second            = 00,   00,
 end_year                = 2021, 2021,
 end_month               = 12,   12,
 end_day                 = 30,   30,
 end_hour                = 18,   18,
 end_minute              = 00,   00,
 end_second              = 00,   00,
 interval_seconds        = 3600,
 input_from_file         = .true., .false.,
 history_interval        = 60, 60,
 frames_per_outfile      = 1, 1,
 restart                 = .false.,
 restart_interval        = 9999,
 io_form_history         = 2,
 io_form_restart         = 2,
 io_form_input           = 2,
 io_form_boundary        = 2,
 auxinput1_inname        = "met_em.d<domain>.<date>",
/

&domains
 time_step               = 12,
 time_step_fract_num     = 0,
 time_step_fract_den     = 1,
 max_dom                 = 2,
 e_we                    = 200, 61,
 e_sn                    = 200, 61,
 e_vert                  = 80, 80,
 p_top_requested         = 5000,
 num_metgrid_levels      = 51,
 num_metgrid_soil_levels = 8,
 dx                      = 3000, 1000,
 dy                      = 3000, 1000,
 grid_id                 = 1, 2,
 parent_id               = 0, 1,
 i_parent_start          = 1, 31,
 j_parent_start          = 1, 17,
 parent_grid_ratio       = 1, 3,
 parent_time_step_ratio  = 1, 3,
 feedback                = 1,
 smooth_option           = 0,
/

&physics
 mp_physics              = 6, 6,
 ra_lw_physics           = 0, 0,
 ra_sw_physics           = 0, 0,
 radt                    = 15, 15,
 sf_sfclay_physics       = 1, 1,
 sf_surface_physics      = 1, 1,
 bl_pbl_physics          = 1, 1,
 cu_physics              = 0, 0,
 num_land_cat            = 21,
 sf_urban_physics        = 0, 0,
 num_soil_layers         = 4,
/

&fdda
/

&dynamics
 hybrid_opt              = 2,
 w_damping               = 1,
 diff_opt                = 1, 1,
 km_opt                  = 4, 4,
 diff_6th_opt            = 0, 0,
 diff_6th_factor         = 0.12, 0.12,
 base_temp               = 290.,
 damp_opt                = 3,
 zdamp                   = 5000., 5000.,
 dampcoef                = 0.2, 0.2,
 khdif                   = 0, 0,
 kvdif                   = 0, 0,
 non_hydrostatic         = .true., .true.,
 moist_adv_opt           = 1, 1,
 scalar_adv_opt          = 1, 1,
/

&bdy_control
 spec_bdy_width          = 5,
 specified               = .true.,
/

&namelist_quilt
 nio_tasks_per_group     = 0,
 nio_groups              = 1,
/
EOF

sed \
  -e 's/max_dom                 = 2,/max_dom                 = 1,/' \
  -e 's/input_from_file         = .true., .false.,/input_from_file         = .true.,/' \
  "$out_dir/namelist.wrf.input" >"$out_dir/namelist.real.input"

cp -f "$out_dir/namelist.real.input" "$out_dir/namelist.input"

cat <<EOF
Packaged nested smoke case at:
  $out_dir

Next commands:
  "$repo_root/gpu-port-checkpoints/run_nested_smoke_2021_mpi.sh" run "$out_dir" "$source_case" "$build_dir"

Expected outputs after real:
  wrfinput_d01
  wrfbdy_d01

Expected smoke outputs after wrf:
  wrfout_d01_2021-12-30_17:00:00
  wrfout_d02_2021-12-30_17:00:00
EOF
