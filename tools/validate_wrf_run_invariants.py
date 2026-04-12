#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable

import netCDF4
import numpy as np


SUCCESS_PATTERN = "SUCCESS COMPLETE WRF"
FINITE_VARS = ("MU", "T", "QVAPOR", "QCLOUD", "QRAIN", "QICE", "QSNOW")
NONNEGATIVE_MOIST_VARS = ("QVAPOR", "QCLOUD", "QRAIN", "QICE", "QSNOW")


@dataclass(frozen=True)
class NamelistTimeControl:
    max_dom: int
    start_times: list[datetime]
    end_times: list[datetime]
    history_intervals_minutes: list[int]


def _extract_assignment(text: str, key: str) -> str:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.+?),\s*$", re.MULTILINE)
    match = pattern.search(text)
    if not match:
        raise ValueError(f"missing namelist assignment for {key!r}")
    return match.group(1)


def _parse_int_list(text: str, key: str) -> list[int]:
    raw = _extract_assignment(text, key)
    values = []
    for part in raw.split(","):
      token = part.strip()
      if not token:
        continue
      values.append(int(token))
    if not values:
        raise ValueError(f"empty integer list for {key!r}")
    return values


def _expand(values: list[int], max_dom: int, key: str) -> list[int]:
    if len(values) == max_dom:
        return values
    if len(values) == 1:
        return values * max_dom
    raise ValueError(f"{key!r} has {len(values)} values but max_dom={max_dom}")


def parse_namelist_time_control(path: Path) -> NamelistTimeControl:
    text = path.read_text()
    max_dom = _parse_int_list(text, "max_dom")[0]

    start_year = _expand(_parse_int_list(text, "start_year"), max_dom, "start_year")
    start_month = _expand(_parse_int_list(text, "start_month"), max_dom, "start_month")
    start_day = _expand(_parse_int_list(text, "start_day"), max_dom, "start_day")
    start_hour = _expand(_parse_int_list(text, "start_hour"), max_dom, "start_hour")
    start_minute = _expand(_parse_int_list(text, "start_minute"), max_dom, "start_minute")
    start_second = _expand(_parse_int_list(text, "start_second"), max_dom, "start_second")

    end_year = _expand(_parse_int_list(text, "end_year"), max_dom, "end_year")
    end_month = _expand(_parse_int_list(text, "end_month"), max_dom, "end_month")
    end_day = _expand(_parse_int_list(text, "end_day"), max_dom, "end_day")
    end_hour = _expand(_parse_int_list(text, "end_hour"), max_dom, "end_hour")
    end_minute = _expand(_parse_int_list(text, "end_minute"), max_dom, "end_minute")
    end_second = _expand(_parse_int_list(text, "end_second"), max_dom, "end_second")

    history_interval = _expand(
        _parse_int_list(text, "history_interval"), max_dom, "history_interval"
    )

    start_times = []
    end_times = []
    for idx in range(max_dom):
        start_times.append(
            datetime(
                start_year[idx],
                start_month[idx],
                start_day[idx],
                start_hour[idx],
                start_minute[idx],
                start_second[idx],
            )
        )
        end_times.append(
            datetime(
                end_year[idx],
                end_month[idx],
                end_day[idx],
                end_hour[idx],
                end_minute[idx],
                end_second[idx],
            )
        )

    return NamelistTimeControl(
        max_dom=max_dom,
        start_times=start_times,
        end_times=end_times,
        history_intervals_minutes=history_interval,
    )


def iter_expected_output_times(start: datetime, end: datetime, history_minutes: int) -> Iterable[datetime]:
    if history_minutes <= 0:
        raise ValueError(f"history_interval must be positive, got {history_minutes}")
    step = timedelta(minutes=history_minutes)
    current = start
    while current <= end:
        yield current
        current += step


def format_wrf_timestamp(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%d_%H:%M:%S")


def expected_wrfout_path(case_dir: Path, domain: int, ts: datetime) -> Path:
    return case_dir / f"wrfout_d{domain:02d}_{format_wrf_timestamp(ts)}"


def read_times_value(dataset: netCDF4.Dataset) -> str:
    if "Times" not in dataset.variables:
        raise ValueError("missing Times variable")
    raw = dataset.variables["Times"][:]
    if raw.shape[0] < 1:
        raise ValueError("Times variable is empty")
    converted = netCDF4.chartostring(raw)
    value = converted[-1]
    if isinstance(value, bytes):
        return value.decode("ascii").strip()
    return str(value).strip()


def require_success_marker(case_dir: Path) -> int:
    hits = 0
    for path in sorted(case_dir.glob("rsl.out.*")) + sorted(case_dir.glob("rsl.error.*")):
        text = path.read_text(errors="ignore")
        hits += text.count(SUCCESS_PATTERN)
    if hits < 1:
        raise ValueError(f"missing {SUCCESS_PATTERN!r} in RSL logs under {case_dir}")
    return hits


def summarize_array(values: np.ndarray) -> tuple[float, float]:
    finite_vals = values[np.isfinite(values)]
    if finite_vals.size == 0:
        return math.nan, math.nan
    return float(np.min(finite_vals)), float(np.max(finite_vals))


def validate_dataset_fields(
    path: Path,
    moist_min_tol: float,
) -> list[str]:
    results: list[str] = []
    with netCDF4.Dataset(path) as ds:
        if "Time" not in ds.dimensions:
            raise ValueError(f"{path} missing Time dimension")
        if not ds.dimensions["Time"].isunlimited():
            raise ValueError(f"{path} Time dimension is not UNLIMITED")

        expected_time = path.name.split("wrfout_d", 1)[1].split("_", 1)[1]
        actual_time = read_times_value(ds)
        if actual_time != expected_time:
            raise ValueError(f"{path} Times[-1]={actual_time!r} != filename time {expected_time!r}")

        for var_name in FINITE_VARS:
            if var_name not in ds.variables:
                continue
            arr = np.asarray(ds.variables[var_name][-1])
            if not np.isfinite(arr).all():
                raise ValueError(f"{path} variable {var_name} contains non-finite values")
            vmin, vmax = summarize_array(arr)
            results.append(f"{var_name}[min={vmin:.6g}, max={vmax:.6g}]")

        for var_name in NONNEGATIVE_MOIST_VARS:
            if var_name not in ds.variables:
                continue
            arr = np.asarray(ds.variables[var_name][-1])
            vmin = float(np.min(arr))
            if vmin < -moist_min_tol:
                raise ValueError(
                    f"{path} variable {var_name} minimum {vmin:.6g} < -{moist_min_tol:.6g}"
                )
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate WRF run completion and basic invariants")
    parser.add_argument("namelist", type=Path, help="namelist.wrf.input to validate against")
    parser.add_argument("case_dir", type=Path, help="case directory containing wrfout/rsl files")
    parser.add_argument(
        "--moist-min-tol",
        type=float,
        default=1.0e-10,
        help="allowed negative tolerance for moist species minima",
    )
    args = parser.parse_args()

    namelist = args.namelist.resolve()
    case_dir = args.case_dir.resolve()
    if not namelist.is_file():
        raise SystemExit(f"missing namelist: {namelist}")
    if not case_dir.is_dir():
        raise SystemExit(f"missing case directory: {case_dir}")

    cfg = parse_namelist_time_control(namelist)
    success_hits = require_success_marker(case_dir)

    print(f"wrf invariant check OK: success markers={success_hits}")
    for domain in range(1, cfg.max_dom + 1):
        start = cfg.start_times[domain - 1]
        end = cfg.end_times[domain - 1]
        history_minutes = cfg.history_intervals_minutes[domain - 1]
        expected_times = list(iter_expected_output_times(start, end, history_minutes))
        expected_paths = [expected_wrfout_path(case_dir, domain, ts) for ts in expected_times]
        missing = [path for path in expected_paths if not path.is_file()]
        if missing:
            missing_list = ", ".join(path.name for path in missing)
            raise SystemExit(f"missing wrfout files for domain d{domain:02d}: {missing_list}")

        final_path = expected_paths[-1]
        field_summaries = validate_dataset_fields(final_path, args.moist_min_tol)
        print(
            f"  d{domain:02d}: outputs={len(expected_paths)} final={final_path.name} "
            f"interval={history_minutes}m"
        )
        if field_summaries:
            print(f"    fields: {', '.join(field_summaries)}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"wrf invariant check failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
