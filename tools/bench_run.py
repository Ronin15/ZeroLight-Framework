#!/usr/bin/env python3
"""Run `zig build bench`, save the output, and rotate old runs.

Each invocation writes a timestamped, header-stamped copy of the benchmark
output to ``benchmark_outputs/`` (gitignored) and prunes the directory down to
the most recent ``--keep`` runs. A ``latest.txt`` symlink always points at the
newest run for quick diffing.

Usage:
    tools/bench_run.py                 # run, save, rotate (keep 20)
    tools/bench_run.py --keep 50       # keep a deeper history window
    tools/bench_run.py -- --details    # forward args to the bench binary
    tools/bench_run.py --no-strip      # keep the ThreadSystem debug lines
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

OUTPUT_DIRNAME = "benchmark_outputs"
RUN_PREFIX = "bench-"
RUN_SUFFIX = ".txt"
LATEST_NAME = "latest.txt"
DEFAULT_KEEP = 20

# Per-group repetition noise: the thread pool logs its init on every group.
DEBUG_NOISE = re.compile(r"^debug\(app\): ThreadSystem initialized:")


def repo_root() -> Path:
    """Resolve the repository root from this script's location."""
    return Path(__file__).resolve().parent.parent


def git_value(root: Path, *args: str) -> str:
    try:
        out = subprocess.run(
            ["git", *args],
            cwd=root,
            capture_output=True,
            text=True,
            check=True,
        )
        return out.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def build_header(root: Path, bench_args: list[str], now: datetime.datetime) -> str:
    commit = git_value(root, "rev-parse", "--short", "HEAD")
    branch = git_value(root, "rev-parse", "--abbrev-ref", "HEAD")
    dirty = git_value(root, "status", "--porcelain")
    commit_state = f"{commit}{'-dirty' if dirty else ''}"
    args_str = " ".join(bench_args) if bench_args else "(none)"
    lines = [
        "# zig build bench",
        f"# date     {now.isoformat(timespec='seconds')}",
        f"# commit   {commit_state}",
        f"# branch   {branch}",
        f"# host     {os.uname().nodename}",
        f"# cpus     {os.cpu_count()}",
        f"# args     {args_str}",
        "#" + "-" * 60,
        "",
    ]
    return "\n".join(lines)


def run_bench(root: Path, bench_args: list[str], strip_noise: bool) -> tuple[int, str]:
    """Run the bench, streaming to the console and capturing the text."""
    cmd = ["zig", "build", "bench"]
    if bench_args:
        cmd += ["--", *bench_args]

    proc = subprocess.Popen(
        cmd,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    captured: list[str] = []
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        if strip_noise and DEBUG_NOISE.match(line):
            continue
        captured.append(line)
    code = proc.wait()
    return code, "".join(captured)


def rotate(output_dir: Path, keep: int) -> list[Path]:
    """Prune to the newest ``keep`` runs. Returns the removed paths."""
    runs = sorted(
        (p for p in output_dir.glob(f"{RUN_PREFIX}*{RUN_SUFFIX}") if p.is_file()),
        key=lambda p: p.name,
    )
    if len(runs) <= keep:
        return []
    removed = runs[: len(runs) - keep]
    for p in removed:
        p.unlink()
    return removed


def update_latest(output_dir: Path, target: Path) -> None:
    link = output_dir / LATEST_NAME
    if link.exists() or link.is_symlink():
        link.unlink()
    try:
        link.symlink_to(target.name)
    except OSError:
        # Filesystems without symlink support: fall back to a plain copy.
        link.write_text(target.read_text())


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run zig build bench, save the output, and rotate old runs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--keep",
        type=int,
        default=DEFAULT_KEEP,
        help=f"number of runs to retain (default: {DEFAULT_KEEP})",
    )
    parser.add_argument(
        "--no-strip",
        action="store_true",
        help="keep the repetitive ThreadSystem debug lines in the saved file",
    )
    parser.add_argument(
        "bench_args",
        nargs="*",
        help="arguments forwarded to the bench binary (use -- to separate)",
    )
    args = parser.parse_args()

    if args.keep < 1:
        parser.error("--keep must be >= 1")

    root = repo_root()
    output_dir = root / OUTPUT_DIRNAME
    output_dir.mkdir(exist_ok=True)

    now = datetime.datetime.now()
    code, captured = run_bench(root, args.bench_args, strip_noise=not args.no_strip)

    stamp = now.strftime("%Y%m%d-%H%M%S")
    run_path = output_dir / f"{RUN_PREFIX}{stamp}{RUN_SUFFIX}"
    header = build_header(root, args.bench_args, now)
    footer = "" if code == 0 else f"\n# exit status: {code} (bench FAILED)\n"
    run_path.write_text(header + captured + footer)
    update_latest(output_dir, run_path)

    removed = rotate(output_dir, args.keep)

    rel = run_path.relative_to(root)
    print(f"\nsaved: {rel}", file=sys.stderr)
    if removed:
        names = ", ".join(p.name for p in removed)
        print(f"rotated out {len(removed)} old run(s): {names}", file=sys.stderr)
    if code != 0:
        print(f"WARNING: bench exited with status {code}", file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
