#!/usr/bin/env python3
"""Targeted before/after benchmark comparison in Debug.

Runs only the named bench groups (never the full suite), interleaving a base
git ref against the working tree for N reps, and prints per-(group, item,
case) medians, each side's min-max spread, and a verdict: a change counts only
when the two sides' min-max ranges do not overlap
(`.claude/rules/tests-benchmarks.md`).

The base ref is exported once with `git archive` under
`benchmark_outputs/ab-base/<sha>/` and reused while it exists (its build cache
stays warm; both sides share the repo's `.zig-cache`, so a new base rebuilds
only what differs). Raw outputs and the summary go to
`benchmark_outputs/ab-<stamp>/`. Cases default to `serial-direct` and
`thread-adaptive-tuned-range`; the forced-thread cases are scheduler controls
(`--all-cases` runs every case).

Usage:
    tools/bench_ab.py --group chunk-scale-dig
    tools/bench_ab.py --group chunk-scale-cave-in --group chunk-scale-explosion-fill \\
        --case serial-direct --case thread-adaptive-tuned-range
    tools/bench_ab.py --group-prefix chunk-scale- --case serial-direct --base main
    tools/bench_ab.py --base none --group nav-update-scattered    # tree only, N reps
    tools/bench_ab.py --group pathfinding -- --items 2000         # forward bench args
"""

from __future__ import annotations

import argparse
import datetime
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

OUTPUT_DIRNAME = "benchmark_outputs"
BASE_DIRNAME = "ab-base"
KEEP_BASES = 2
READY_MARKER = ".bench-ab-ready"

GROUP_HEADER = re.compile(r"^(\S+)\s+(\d+)\s+\S")
CASE_ROW = re.compile(r"^(\S+)\s+([\d.]+)\s+(ns|us|ms|s)\s")
UNIT_US = {"ns": 1e-3, "us": 1.0, "ms": 1e3, "s": 1e6}
DEFAULT_CASES = ("serial-direct", "thread-adaptive-tuned-range")


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True).stdout.strip()


def export_base(root: Path, ref: str) -> Path:
    """Export `ref` once per commit; prune older exports to KEEP_BASES."""
    sha = git(root, "rev-parse", "--verify", f"{ref}^{{commit}}")
    bases = root / OUTPUT_DIRNAME / BASE_DIRNAME
    target = bases / sha[:12]
    if not (target / READY_MARKER).exists():
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        archive = subprocess.Popen(["git", "archive", sha], cwd=root, stdout=subprocess.PIPE)
        subprocess.run(["tar", "-x", "-C", str(target)], stdin=archive.stdout, check=True)
        if archive.wait() != 0:
            raise SystemExit(f"git archive {ref} failed")
        (target / READY_MARKER).write_text(sha + "\n")
    target.touch()
    others = sorted((p for p in bases.iterdir() if p.is_dir() and p != target), key=lambda p: p.stat().st_mtime)
    for old in others[: max(0, len(others) - (KEEP_BASES - 1))]:
        shutil.rmtree(old)
    return target


def run_bench(cwd: Path, bench_args: list[str], cache_dir: Path) -> tuple[int, str]:
    # Both sides share the repo's local cache: it is content-addressed, so a base
    # export of a new parent commit rebuilds only what differs instead of cold.
    cmd = ["zig", "build", "bench", "--cache-dir", str(cache_dir), "--", *bench_args]
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def parse(text: str, case_filter: str | None) -> dict[tuple[str, str, str], float]:
    """(group, item code, case) -> mean in microseconds."""
    out: dict[tuple[str, str, str], float] = {}
    group = item = None
    for line in text.splitlines():
        row = CASE_ROW.match(line)
        if row and group is not None:
            case = row.group(1)
            # First row per case is the compact table's mean; --details rows follow.
            if (case_filter is None or case == case_filter) and (group, item, case) not in out:
                out[(group, item, case)] = float(row.group(2)) * UNIT_US[row.group(3)]
            continue
        header = GROUP_HEADER.match(line)
        if header and not line.startswith(("case ", "summary", "details", "benchmark", "purpose", "worker")):
            group, item = header.group(1), header.group(2)
    return out


def fmt_us(v: float) -> str:
    if v >= 1e3:
        return f"{v / 1e3:.2f} ms"
    return f"{v:.1f} us"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Targeted Debug A/B bench: base ref vs working tree, interleaved reps, medians.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--group", action="append", default=[], help="bench group (repeatable)")
    parser.add_argument("--group-prefix", action="append", default=[], help="bench group prefix (repeatable)")
    parser.add_argument(
        "--case",
        action="append",
        default=[],
        help="bench case (repeatable; default: serial-direct and thread-adaptive-tuned-range)",
    )
    parser.add_argument("--all-cases", action="store_true", help="run every bench case")
    parser.add_argument("--base", default="HEAD", help="git ref for the before side, or 'none' (default: HEAD)")
    parser.add_argument("--reps", type=int, default=3, help="interleaved reps per side (default: 3)")
    parser.add_argument("bench_args", nargs="*", help="extra args forwarded to the bench binary (after --)")
    args = parser.parse_args()

    if not args.group and not args.group_prefix:
        parser.error("name at least one --group or --group-prefix; full-suite sweeps use tools/bench_run.py")
    if args.reps < 1:
        parser.error("--reps must be >= 1")

    root = repo_root()
    sides: list[tuple[str, Path]] = []
    if args.base != "none":
        sides.append((f"base:{args.base}", export_base(root, args.base)))
    sides.append(("tree", root))

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = root / OUTPUT_DIRNAME / f"ab-{stamp}"
    out_dir.mkdir(parents=True)

    targets = [["--group", g] for g in args.group] + [["--group-prefix", p] for p in args.group_prefix]
    if args.all_cases and args.case:
        parser.error("--all-cases and --case are exclusive")
    cases: list[str | None] = [None] if args.all_cases else (list(args.case) or list(DEFAULT_CASES))
    samples: dict[tuple[str, str, str, str], list[float]] = {}

    total = args.reps * len(targets) * len(cases) * len(sides)
    done = 0
    for rep in range(1, args.reps + 1):
        for target in targets:
            for case in cases:
                for name, cwd in sides:
                    bench_args = target + (["--case", case] if case else []) + args.bench_args
                    code, text = run_bench(cwd, bench_args, root / ".zig-cache")
                    tag = "_".join([name.replace(":", "-").replace("/", "-"), target[1], case or "all", str(rep)])
                    (out_dir / f"{tag}.txt").write_text(text)
                    done += 1
                    print(f"[{done}/{total}] {name} {' '.join(bench_args)}", file=sys.stderr)
                    if code != 0:
                        print(text[-4000:], file=sys.stderr)
                        print(f"bench failed on {name} (exit {code}); raw output in {out_dir}", file=sys.stderr)
                        return code
                    for (group, item, case_name), us in parse(text, case).items():
                        samples.setdefault((group, item, case_name, name), []).append(us)

    keys = sorted({k[:3] for k in samples})
    names = [n for n, _ in sides]
    lines = [
        f"# bench_ab  {stamp}  head={git(root, 'rev-parse', '--short', 'HEAD')}"
        f"{'-dirty' if git(root, 'status', '--porcelain') else ''}  reps={args.reps}  Debug",
        f"# args  {' '.join(sum(targets, []))}  cases={'all' if args.all_cases else ','.join(c for c in cases)}  extra={' '.join(args.bench_args) or '-'}",
        "",
    ]
    header = f"{'group':30} {'item':>12} {'case':28}"
    for n in names:
        header += f" {n[:18]:>18} {'spread':>7}"
    if len(names) == 2:
        header += f" {'delta':>8}  verdict"
    lines.append(header)
    for key in keys:
        row = f"{key[0]:30} {key[1]:>12} {key[2]:28}"
        stats = []
        for n in names:
            vals = samples.get(key + (n,), [])
            if not vals:
                row += f" {'-':>18} {'-':>7}"
                stats.append(None)
                continue
            med = statistics.median(vals)
            spread = (max(vals) - min(vals)) / med * 100 if med else 0.0
            row += f" {fmt_us(med):>18} {spread:6.1f}%"
            stats.append((med, min(vals), max(vals)))
        if len(names) == 2 and all(stats):
            (bm, blo, bhi), (tm, tlo, thi) = stats
            delta = (tm - bm) / bm * 100 if bm else 0.0
            verdict = "slower" if tlo > bhi else "faster" if thi < blo else "within spread"
            row += f" {delta:+7.1f}%  {verdict}"
        lines.append(row)
    summary = "\n".join(lines) + "\n"
    (out_dir / "summary.txt").write_text(summary)
    print(summary)
    print(f"raw outputs and summary: {out_dir.relative_to(root)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
