#!/usr/bin/env python3
"""Targeted before/after benchmark comparison, in Debug by default.

Runs only the named bench groups (never the full suite), a base git ref
against the working tree, one run per side by default, and prints per-(group,
item, case) times and a verdict (`.claude/rules/tests-benchmarks.md`). One run
per side: a change beyond NOISE_PCT counts, and a `slower` case is confirmed by
rerunning only that group, size, and case with `--reps 3`. With reps, it prints
medians and min-max spread, and a change counts only when the two sides' ranges
do not overlap.

The base ref is exported once with `git archive` under
`benchmark_outputs/ab-base/<sha>/` and reused while it exists (its build cache
stays warm; both sides share the repo's `.zig-cache`, so a new base rebuilds
only what differs). Raw outputs and the summary go to
`benchmark_outputs/ab-<stamp>/`. Cases default to `serial-direct` and
`thread-adaptive-tuned-range`; the forced-thread cases are scheduler controls
(`--all-cases` runs every case). A run must name its config with
`-- --items N` (or pass `--grid` for every config): one config answers a
regression question; a full grid is rarely the right signal. Runs use `--warmup 2 --iterations 10`
unless the forwarded bench args set them.

Each side's raw outputs are cached under `benchmark_outputs/ab-cache/`, keyed
by the side's build inputs (`src/`, `build.zig*`, `assets/` as git trees, the
working tree's content included, so a landing's measured tree is the next
landing's cached base), the build mode, the CPU, the case, and the
forwarded args. A side with enough cached reps younger than
`CACHE_MAX_AGE_S` is not rerun; that side is then not interleaved with the
other, so `--fresh` reruns both when a verdict sits at the edge of spread. `--optimize ReleaseFast` is only for a
question Debug cannot answer (`.claude/rules/build-validation.md`).

Both sides build with the same explicit `-Dcpu`, by default the host's shipped
CPU floor (the mapping in `build.zig`'s `shippedCpuFloor`: `x86_64_v2` on
x86-64, `apple_m1` on macOS arm64, `baseline` elsewhere), so a base ref from
before Debug defaulted to the floor still builds at the tree's CPU. `--cpu`
overrides it for both sides (`--cpu native`). The CPU is part of the cache key,
so runs at another CPU are never reused.

Usage:
    tools/bench_ab.py --group chunk-scale-dig -- --items 1024032
    tools/bench_ab.py --group chunk-scale-cave-in -- --items 2561024032
    tools/bench_ab.py --group chunk-scale-gpu-sync-dig --case serial-direct --base 5439e36 -- --items 1024032
    tools/bench_ab.py --base none --grid --group chunk-scale-dig   # shape: tree only, every config
    tools/bench_ab.py --group pathfinding -- --items 2000         # forward bench args
    tools/bench_ab.py --optimize ReleaseFast --group movement-apply-intents -- --items 16384
    tools/bench_ab.py --cpu native --group ai -- --items 1024         # both sides at the host CPU
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

OUTPUT_DIRNAME = "benchmark_outputs"
BASE_DIRNAME = "ab-base"
KEEP_BASES = 2
READY_MARKER = ".bench-ab-ready"
CACHE_DIRNAME = "ab-cache"
# Cached reps older than this are rerun: machine state drifts across a day.
CACHE_MAX_AGE_S = 6 * 3600

GROUP_HEADER = re.compile(r"^(\S+)\s+(\d+)\s+\S")
CASE_ROW = re.compile(r"^(\S+)\s+([\d.]+)\s+(ns|us|ms|s)\s")
UNIT_US = {"ns": 1e-3, "us": 1.0, "ms": 1e3, "s": 1e6}
DEFAULT_CASES = ("serial-direct", "thread-adaptive-tuned-range")
# Single-run verdict band; a regression past it is confirmed with --reps 3.
NOISE_PCT = 10.0
# A regression check needs medians and spread over reps, not long runs per config.
DEFAULT_TIMING = ("--warmup", "2", "--iterations", "10")


def host_target() -> tuple[str, str]:
    """(arch, os) of the host as Zig resolves it (`zig env` `.target`), so an emulated
    Python interpreter (Rosetta) never picks the wrong floor."""
    try:
        out = subprocess.run(["zig", "env"], capture_output=True, text=True, check=True).stdout
        match = re.search(r'\.target = "([^-"]+)-([^-."]+)', out)
        if match:
            return match.group(1), match.group(2)
    except (OSError, subprocess.CalledProcessError):
        pass
    return platform.machine().lower(), sys.platform


def shipped_cpu_floor() -> str:
    """The host's shipped CPU floor, matching `shippedCpuFloor` in build.zig."""
    arch, os_name = host_target()
    if arch in ("x86_64", "amd64"):
        return "x86_64_v2"
    if arch in ("arm64", "aarch64") and os_name in ("macos", "darwin"):
        return "apple_m1"
    return "baseline"


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


# Only these paths change what a bench measures; docs, rules, and tools do not.
BUILD_INPUTS = ("src", "build.zig", "build.zig.zon", "assets")


def tree_of(root: Path, ref: str | None) -> str:
    """Id of the bench's build inputs at a ref, or in the working tree (untracked included)."""
    if ref is not None:
        tree = git(root, "rev-parse", f"{ref}^{{tree}}")
    else:
        with tempfile.TemporaryDirectory() as scratch:
            env = {**os.environ, "GIT_INDEX_FILE": str(Path(scratch) / "index")}
            subprocess.run(["git", "read-tree", "HEAD"], cwd=root, env=env, check=True)
            subprocess.run(["git", "add", "-A"], cwd=root, env=env, check=True)
            tree = subprocess.run(["git", "write-tree"], cwd=root, env=env, capture_output=True, text=True, check=True).stdout.strip()
    parts = [subprocess.run(["git", "rev-parse", f"{tree}:{path}"], cwd=root, capture_output=True, text=True).stdout.strip() for path in BUILD_INPUTS]
    return hashlib.sha256(" ".join(parts).encode()).hexdigest()


def cache_path(root: Path, tree: str, optimize: str, cpu: str, bench_args: list[str]) -> Path:
    digest = hashlib.sha256(json.dumps([optimize, cpu, bench_args]).encode()).hexdigest()[:16]
    return root / OUTPUT_DIRNAME / CACHE_DIRNAME / tree[:16] / f"{digest}.json"


def cached_texts(path: Path, reps: int) -> list[str] | None:
    try:
        entry = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if time.time() - entry.get("created", 0) > CACHE_MAX_AGE_S or len(entry.get("texts", [])) < reps:
        return None
    return entry["texts"][:reps]


def run_bench(cwd: Path, bench_args: list[str], cache_dir: Path, optimize: str, cpu: str) -> tuple[int, str]:
    # Both sides share the repo's local cache: it is content-addressed, so a base
    # export of a new parent commit rebuilds only what differs instead of cold.
    cmd = ["zig", "build", "bench", f"-Doptimize={optimize}", f"-Dcpu={cpu}", "--cache-dir", str(cache_dir), "--", *bench_args]
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
        description="Targeted A/B bench (Debug by default): base ref vs working tree, one run per side or medians over reps.",
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
    parser.add_argument(
        "--grid",
        action="store_true",
        help="run every config of each group (default: refuse unless the forwarded args name --items)",
    )
    parser.add_argument("--base", default="HEAD", help="git ref for the before side, or 'none' (default: HEAD)")
    parser.add_argument("--reps", type=int, default=1, help="interleaved reps per side (default: 1; 3 to confirm a slower case)")
    parser.add_argument(
        "--optimize",
        choices=("Debug", "ReleaseFast"),
        default="Debug",
        help="build mode for both sides (default: Debug; ReleaseFast only for what Debug cannot show)",
    )
    parser.add_argument(
        "--cpu",
        default=shipped_cpu_floor(),
        help="-Dcpu for both sides (default: the host's shipped CPU floor, %(default)s; e.g. native)",
    )
    parser.add_argument("--fresh", action="store_true", help="ignore cached reps and rerun both sides")
    parser.add_argument("bench_args", nargs="*", help="extra args forwarded to the bench binary (after --)")
    args = parser.parse_args()

    if not args.group and not args.group_prefix:
        parser.error("name at least one --group or --group-prefix; full-suite sweeps use tools/bench_run.py")
    names_items = any(a.startswith("--items") for a in args.bench_args)
    if not names_items and not args.grid:
        parser.error("name the config that answers the question (-- --items N), or pass --grid for every config")
    if args.reps < 1:
        parser.error("--reps must be >= 1")

    root = repo_root()
    sides: list[tuple[str, Path, str]] = []
    if args.base != "none":
        sides.append((f"base:{args.base}", export_base(root, args.base), tree_of(root, args.base)))
    sides.append(("tree", root, tree_of(root, None)))

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = root / OUTPUT_DIRNAME / f"ab-{stamp}"
    suffix = 2
    while out_dir.exists():  # runs started within the same second
        out_dir = root / OUTPUT_DIRNAME / f"ab-{stamp}-{suffix}"
        suffix += 1
    out_dir.mkdir(parents=True)

    timing = [] if any(a.startswith(("--warmup", "--iterations")) for a in args.bench_args) else list(DEFAULT_TIMING)
    targets = [["--group", g] for g in args.group] + [["--group-prefix", p] for p in args.group_prefix]
    if args.all_cases and args.case:
        parser.error("--all-cases and --case are exclusive")
    cases: list[str | None] = [None] if args.all_cases else (list(args.case) or list(DEFAULT_CASES))
    samples: dict[tuple[str, str, str, str], list[float]] = {}
    texts: dict[tuple[int, int, int], list[str]] = {}
    cached_sides: set[str] = set()
    for t, target in enumerate(targets):
        for c, case in enumerate(cases):
            for s, (name, _, tree) in enumerate(sides):
                bench_args = target + (["--case", case] if case else []) + timing + args.bench_args
                hit = None if args.fresh else cached_texts(cache_path(root, tree, args.optimize, args.cpu, bench_args), args.reps)
                if hit is not None:
                    texts[(t, c, s)] = hit
                    cached_sides.add(name)

    total = sum(args.reps for t in range(len(targets)) for c in range(len(cases)) for s in range(len(sides)) if (t, c, s) not in texts)
    done = 0
    fresh: dict[tuple[int, int, int], list[str]] = {}
    for rep in range(1, args.reps + 1):
        for t, target in enumerate(targets):
            for c, case in enumerate(cases):
                for s, (name, cwd, _) in enumerate(sides):
                    if (t, c, s) in texts:
                        continue
                    bench_args = target + (["--case", case] if case else []) + timing + args.bench_args
                    code, text = run_bench(cwd, bench_args, root / ".zig-cache", args.optimize, args.cpu)
                    tag = "_".join([name.replace(":", "-").replace("/", "-"), target[1], case or "all", str(rep)])
                    (out_dir / f"{tag}.txt").write_text(text)
                    done += 1
                    print(f"[{done}/{total}] {name} -Dcpu={args.cpu} {' '.join(bench_args)}", file=sys.stderr)
                    if code != 0:
                        print(text[-4000:], file=sys.stderr)
                        print(f"bench failed on {name} (exit {code}); raw output in {out_dir}", file=sys.stderr)
                        return code
                    fresh.setdefault((t, c, s), []).append(text)

    for (t, c, s), runs in fresh.items():
        bench_args = targets[t] + (["--case", cases[c]] if cases[c] else []) + timing + args.bench_args
        path = cache_path(root, sides[s][2], args.optimize, args.cpu, bench_args)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"created": time.time(), "cpu": args.cpu, "args": bench_args, "texts": runs}))
    for (t, c, s), runs in {**texts, **fresh}.items():
        for text in runs:
            for (group, item, case_name), us in parse(text, cases[c]).items():
                samples.setdefault((group, item, case_name, sides[s][0]), []).append(us)

    keys = sorted({k[:3] for k in samples})
    names = [n for n, _, _ in sides]
    lines = [
        f"# bench_ab  {stamp}  head={git(root, 'rev-parse', '--short', 'HEAD')}"
        f"{'-dirty' if git(root, 'status', '--porcelain') else ''}  reps={args.reps}  {args.optimize}  cpu={args.cpu}",
        f"# args  {' '.join(sum(targets, []))}  cases={'all' if args.all_cases else ','.join(c for c in cases)}  extra={' '.join(args.bench_args) or '-'}",
        f"# cached (not interleaved): {', '.join(sorted(cached_sides)) or 'none'}",
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
            if args.reps == 1:
                verdict = "slower (confirm: --reps 3)" if delta > NOISE_PCT else "faster" if delta < -NOISE_PCT else "within noise"
            else:
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
