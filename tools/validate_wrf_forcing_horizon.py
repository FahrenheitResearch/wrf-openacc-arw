#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


TIME_FMT = "%Y-%m-%d_%H:%M:%S"


def parse_int_list(line: str) -> list[int]:
    rhs = line.split("=", 1)[1]
    vals = []
    for raw in rhs.split(","):
        raw = raw.strip()
        if not raw:
            continue
        if raw.endswith("/"):
            raw = raw[:-1].strip()
        if raw:
            vals.append(int(raw))
    return vals


def parse_end_datetimes(namelist_path: Path) -> list[datetime]:
    fields: dict[str, list[int]] = {}
    wanted = {
        "end_year",
        "end_month",
        "end_day",
        "end_hour",
        "end_minute",
        "end_second",
    }
    for raw_line in namelist_path.read_text().splitlines():
        line = raw_line.strip()
        if "=" not in line:
            continue
        key = line.split("=", 1)[0].strip().lower()
        if key in wanted:
            fields[key] = parse_int_list(line)

    required = ["end_year", "end_month", "end_day", "end_hour", "end_minute"]
    missing = [k for k in required if k not in fields]
    if missing:
        raise ValueError(f"missing namelist end fields: {', '.join(missing)}")

    n = max(len(fields[k]) for k in required)
    datetimes = []
    for i in range(n):
        year = fields["end_year"][min(i, len(fields["end_year"]) - 1)]
        month = fields["end_month"][min(i, len(fields["end_month"]) - 1)]
        day = fields["end_day"][min(i, len(fields["end_day"]) - 1)]
        hour = fields["end_hour"][min(i, len(fields["end_hour"]) - 1)]
        minute = fields["end_minute"][min(i, len(fields["end_minute"]) - 1)]
        second = fields.get("end_second", [0])[min(i, len(fields.get("end_second", [0])) - 1)]
        datetimes.append(datetime(year, month, day, hour, minute, second))
    return datetimes


def latest_met_em(case_dir: Path) -> datetime | None:
    times = []
    for path in sorted(case_dir.glob("met_em.d01.*.nc")):
        stamp = path.name.removeprefix("met_em.d01.").removesuffix(".nc")
        try:
            times.append(datetime.strptime(stamp, TIME_FMT))
        except ValueError:
            continue
    return max(times) if times else None


def latest_wrfbdy(case_dir: Path) -> datetime | None:
    wrfbdy = case_dir / "wrfbdy_d01"
    if not wrfbdy.exists():
        return None
    try:
        proc = subprocess.run(
            [
                "ncdump",
                "-v",
                "Times,md___thisbdytimee_x_t_d_o_m_a_i_n_m_e_t_a_data_,md___nextbdytimee_x_t_d_o_m_a_i_n_m_e_t_a_data_",
                str(wrfbdy),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None

    matches = re.findall(r'"(\d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2})"', proc.stdout)
    if not matches:
        return None
    return max(datetime.strptime(m, TIME_FMT) for m in matches)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate that requested WRF end time does not exceed available forcing coverage."
    )
    parser.add_argument(
        "--source",
        choices=("auto", "met_em", "wrfbdy"),
        default="auto",
        help=(
            "Coverage source to validate against. "
            "'auto' prefers wrfbdy_d01 when present, otherwise met_em.d01.*.nc."
        ),
    )
    parser.add_argument("namelist", type=Path, help="Path to namelist file to validate")
    parser.add_argument(
        "case_dir",
        type=Path,
        nargs="?",
        help="Case directory containing met_em.d01.*.nc and/or wrfbdy_d01 (default: namelist parent)",
    )
    args = parser.parse_args()

    namelist = args.namelist.resolve()
    case_dir = (args.case_dir or namelist.parent).resolve()

    end_times = parse_end_datetimes(namelist)
    requested_end = max(end_times)

    met_end = latest_met_em(case_dir)
    wrfbdy_end = latest_wrfbdy(case_dir)
    if args.source == "auto":
        if wrfbdy_end is not None:
            source_name = "wrfbdy_d01"
            latest_available = wrfbdy_end
        elif met_end is not None:
            source_name = "met_em.d01"
            latest_available = met_end
        else:
            print(
                f"forcing horizon check skipped: no met_em.d01.*.nc or wrfbdy_d01 found under {case_dir}",
                file=sys.stderr,
            )
            return 0
    elif args.source == "met_em":
        if met_end is None:
            print(
                f"forcing horizon check failed: requested met_em.d01 coverage, but none found under {case_dir}",
                file=sys.stderr,
            )
            return 1
        source_name = "met_em.d01"
        latest_available = met_end
    else:
        if wrfbdy_end is None:
            print(
                f"forcing horizon check failed: requested wrfbdy_d01 coverage, but {case_dir / 'wrfbdy_d01'} is missing or unreadable",
                file=sys.stderr,
            )
            return 1
        source_name = "wrfbdy_d01"
        latest_available = wrfbdy_end

    if requested_end > latest_available:
        print(
            f"forcing horizon check failed: requested end {requested_end.strftime(TIME_FMT)} "
            f"exceeds latest available {source_name} time {latest_available.strftime(TIME_FMT)}",
            file=sys.stderr,
        )
        return 1

    print(
        f"forcing horizon OK: requested end {requested_end.strftime(TIME_FMT)} <= "
        f"latest available {source_name} time {latest_available.strftime(TIME_FMT)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
