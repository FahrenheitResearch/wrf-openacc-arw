#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from statistics import mean


TIMING_RE = re.compile(
    r"Timing for main: time (?P<stamp>\S+) on domain\s+(?P<domain>\d+):\s+"
    r"(?P<elapsed>[0-9.]+) elapsed seconds"
)


@dataclass(frozen=True)
class BenchRecord:
    log_path: Path
    domain: int
    stamp: str
    elapsed_seconds: float
    counters: dict[str, int]


def load_timer_names(repo_root: Path) -> list[str]:
    header = repo_root / "inc" / "bench_solve_em_end.h"
    names: list[str] = []
    for line in header.read_text().splitlines():
        line = line.strip()
        if line.startswith("BENCH_REPORT("):
            names.append(line[len("BENCH_REPORT(") : -1])
    if not names:
        raise ValueError(f"no BENCH_REPORT names found in {header}")
    return names


def extract_records(log_path: Path, timer_names: list[str]) -> list[BenchRecord]:
    lines = log_path.read_text(errors="ignore").splitlines()
    records: list[BenchRecord] = []
    for idx, line in enumerate(lines):
        match = TIMING_RE.search(line)
        if not match:
            continue
        start = idx - 1
        while start >= 0 and "A=" in lines[start]:
            start -= 1
        counter_lines = [entry for entry in lines[start + 1 : idx] if "A=" in entry]
        if len(counter_lines) != len(timer_names):
            continue
        counters = {}
        for name, entry in zip(timer_names, counter_lines):
            counters[name] = int(entry.split("A=")[1].strip())
        records.append(
            BenchRecord(
                log_path=log_path,
                domain=int(match.group("domain")),
                stamp=match.group("stamp"),
                elapsed_seconds=float(match.group("elapsed")),
                counters=counters,
            )
        )
    return records


def summarize_group(records: list[BenchRecord], top_n: int) -> str:
    elapsed = [record.elapsed_seconds for record in records]
    latest = records[-1]
    solve_total = max(latest.counters.get("solve_tim", 0), 1)
    top = sorted(latest.counters.items(), key=lambda item: item[1], reverse=True)[:top_n]

    lines = [
        f"steps={len(records)} mean={mean(elapsed):.5f}s min={min(elapsed):.5f}s "
        f"max={max(elapsed):.5f}s latest={latest.elapsed_seconds:.5f}s stamp={latest.stamp}"
    ]
    for name, value in top:
        pct = 100.0 * value / solve_total
        lines.append(f"  {name}: {value} ({pct:.1f}% of solve_tim)")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize WRF BENCH timing blocks from RSL logs")
    parser.add_argument("case_dir", type=Path, help="run directory containing rsl.out/error logs")
    parser.add_argument(
        "--domain",
        type=int,
        action="append",
        default=[],
        help="restrict summary to one or more domains",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=8,
        help="number of top timers to print from the latest step",
    )
    args = parser.parse_args()

    case_dir = args.case_dir.resolve()
    if not case_dir.is_dir():
        raise SystemExit(f"missing case directory: {case_dir}")

    repo_root = Path(__file__).resolve().parent.parent
    timer_names = load_timer_names(repo_root)

    wanted_domains = set(args.domain)
    grouped: dict[tuple[Path, int], list[BenchRecord]] = defaultdict(list)
    for log_path in sorted(case_dir.glob("rsl.out.*")) + sorted(case_dir.glob("rsl.error.*")):
        for record in extract_records(log_path, timer_names):
            if wanted_domains and record.domain not in wanted_domains:
                continue
            grouped[(record.log_path, record.domain)].append(record)

    if not grouped:
        print(f"no BENCH timing blocks found under {case_dir}", file=sys.stderr)
        return 1

    print(f"wrf bench summary: {case_dir}")
    for (log_path, domain), records in sorted(grouped.items(), key=lambda item: (item[0][1], str(item[0][0]))):
        print(f"  log={log_path.name} domain={domain}")
        print(summarize_group(records, args.top))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
