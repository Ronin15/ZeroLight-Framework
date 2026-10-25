#!/usr/bin/env python3
"""Lint Zig sources for idiom/currency regressions.

Enforces a small set of high-signal, low-false-positive rules so the properties
that make this codebase idiomatic stay guaranteed by the build rather than by
reviewer diligence:

1. Current standard-library and builtin spellings (no deprecated/removed
   aliases), including the Zig 0.17 removals (`**` array repeat, `@cImport`,
   `std.meta.fields`, `Allocator.dupeZ`) and deprecated builtins/aliases
   (`@intFromEnum`, `@enumFromInt`, `std.builtin.OptimizeMode`), plus no
   `@hasDecl` in src (0.17 `@hasDecl` sees only `pub` declarations).
2. snake_case struct fields and function parameters (Zig names non-callables
   snake_case); no C++-style camelCase `kFoo` constants.
3. `catch unreachable` / `orelse unreachable` only where it cannot swallow a
   recoverable failure into ReleaseFast UB: on a sanctioned generational-handle
   constructor, inside a `test` block (not shipped), or with an explicit
   `// lint:allow catch-unreachable: <reason>` justification at the site.
4. No scalar NaN self-compare (`x != x` / `x == x`); use std.math.isNan
   (src/core/simd.zig exempt — element-wise vector NaN masks are legitimate).
5. No free-function EntityId equality helper; EntityId.eql owns the primitive.
6. No no-op `catch |e| return e` (or `{ return e; }`); it is just `try`.
7. No camelCase enum tags (Zig enum members are snake_case).
8. No unused file-scope `const` (a dead import or alias): Zig compiles only
   what is referenced, so an unused declaration builds clean and goes stale.
9. No test- or bench-only `pub` API in production code: every `pub` decl in a
   production file is referenced by production code (outside `test` blocks,
   file-scope test helpers (named `*ForTest` / `*WithTestBackend`, or using
   `std.testing`), `*test_support.zig`, `src/benchmarks/`, and the
   test/bench/smoke roots). A `pub fn` name declared more than once needs at
   least as many production call sites as distinct declaration shapes, and a
   non-`pub` method needs a production reference in its own file (methods of
   file-scope test fixtures excepted).
   A `pub` member of a file-private test fixture is not reported when that
   member's name is also a production declaration (`init`, `deinit`,
   `contains`). A clean run does not prove those members are private. A
   cross-file `anytype` hook on such a fixture (`visitLanes`) stays `pub`
   because the caller is another file. Both are review checks, not lint hits.
   Every hit is removed from production; no annotation exempts one. The only
   exemptions are the owner's `OWNER_KEPT_API` entries.
10. No `error.SkipZigTest` under `src/` (tests, benches, and smoke included).
11. A `test` block, and a file-scope helper only tests reach, does not
    reference `runtime_perf_log`, `perf_counters`, or `.perf` (any member access;
    an empty reset `.perf = .{}` reads nothing and is allowed). `src/benchmarks/`
    and `*test_support.zig` may: benches read counters, and support files serve
    benches. Production code outside `test` blocks may too. `build.zig`'s
    `perf_counters` option is not a hit.
12. Relative imports that resolve under `src/` point down. A hit names the
    file, the import, and the layer it crosses. An import that stays inside
    its own layer is not a hit. `src/game/` may import `render/`, `assets/`,
    `core/`, `platform/`, and `src/app/`. `src/app/` may import `src/game/`
    only from the files that construct states (`engine.zig` builds
    `MainMenuState`, `pause_controller.zig` builds `PauseState`). `render/`,
    `assets/`, `core/`, and `platform/` do not import `game/`. `core/` imports
    only `core/`. `platform/` imports only `core/` (and its own layer). No
    layer imports `src/tests.zig`, `src/benchmark_runner.zig`,
    `src/gpu_smoke.zig`, `src/gpu_smoke_impl.zig`, or `src/benchmarks/`.
13. Production dispatch controls are forwards. `ThreadSystem`'s fixed-shape
    options are the test and bench seam; production code only forwards its
    stage's controls into them. A stage-config type is a struct declaring a
    `?usize` `[<stage>_]items_per_range` field (`StageControls`,
    `ParallelForOptions`, `BatchWorkRequest`, `Dispatch`, each system's
    `*Config`) or the `T` of a `StageThreads(T)`; its seam fields are its
    `?usize` `[<stage>_]items_per_range` / `[<stage>_]max_worker_threads`,
    `?f64` `[<stage>_]batches_per_participant`, and `bool`
    `[<stage>_]adaptive` fields. The contexts, resolved across files:
    a stage-config literal (`T{`, `: T = .{`, `return .{` in a function
    returning `T`), a `.{` literal assigned to a name declared with a
    stage-config type (`self.nav_controls = .{`, `.config = .{`), a `.{`
    argument in a stage-config parameter's position (by name, arity, and a
    type receiver's container, as `Dispatch.init(`), and a statement setting
    a seam field, `adaptive_tuner`, or `selected_profile`.
    13.1: a `items_per_range` / `max_worker_threads` /
    `batches_per_participant` seam field set to anything but a forward: the
    same control's declared seam field read from `config` / `<x>_config` /
    `controls` / `<x>_controls` declared with a stage-config type (`orelse`
    chains of them), or the
    selection's own (`selection.items_per_range`, `selection.worker_threads`,
    `shape.items_per_range`; a selection carries no batch count).
    13.2: an `adaptive` seam field set to anything but a forward.
    13.3: a shape no tuner records: `adaptive_tuner` other than a selection's
    `active_tuner`, `selected_profile` other than a selection's `profile`,
    `selectBatchProfile(null, ...)`, or a `parallelForWithOptions` whose
    options literal has no `adaptive_tuner`.
    13.4: a forward of a config's `items_per_range` without its
    `batches_per_participant` forward from the same owner (in the same
    literal, or for a statement, a statement on the same receiver in the
    same block) drops the batch-count control.
    Job-context literals are not contexts. Scope: production files (rule
    9's) minus `src/app/thread_system.zig` (the seam's owner, still read for
    declarations), their `test` blocks, and helpers only tests reach. A
    self-check runs the removed hit lines, one hit per context, and forwards
    first.
Scans every `src/**/*.zig` file plus `build.zig`. Rules in SRC_ONLY_PATTERNS
apply to `src/` only. All rules match code with string/char-literal contents
blanked and `//` comments removed, so text inside literals never trips a rule.

Run via `zig build idiom-lint` (also part of `zig build check` and `zig build verify`).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "src"
BUILD_FILE = REPO_ROOT / "build.zig"

# Fallible constructors that fail only on inputs already guarded at every call
# site (index == maxInt / generation == 0), so `X.init(...) catch unreachable`
# is provably infallible by construction. Keep this list in sync with the
# generational-handle types; adding a new one is a deliberate, reviewed change.
HANDLE_CTOR = re.compile(
    r"\b(?:TextureId|FontId|TextTextureId|EntityId|LeaseHandle)\.init\s*\("
)
CATCH_UNREACHABLE = re.compile(r"\b(?:catch|orelse)\s+unreachable\b")
# Require a non-empty reason after the colon. Bare
# `// lint:allow catch-unreachable` or empty `...: ` do not allow.
ALLOW_ANNOTATION = re.compile(r"lint:allow catch-unreachable:\s*\S+")

# Scalar NaN self-comparison (`x != x` / `x == x`). std.math.isNan is the
# canonical spelling (see src/core/math.zig); a hand-rolled self-compare is idiom
# drift. Operands are boundary-anchored to a single maximal token so member/index
# accesses and `x == x - 1` style expressions (different real operands) do not
# match. src/core/simd.zig is exempt: element-wise `@Vector != @Vector` NaN masks
# are legitimate there and std.math.isNan (scalar-only) does not apply.
NAN_SELF_COMPARE = re.compile(
    r"(?<![\w.\]\)])([A-Za-z_][\w.]*)\s*(?:==|!=)\s*([A-Za-z_][\w.]*)(?![\w.\[(]|\s*[-+*/%<>])"
)
NAN_SELF_COMPARE_EXEMPT = {"src/core/simd.zig"}

# A `catch` whose whole body just re-returns the same error binding — `... catch
# |e| return e;` or `... catch |e| { return e; }`. That is exactly `try` with no
# cleanup, logging, or translation, and it reads as if it intends handling it does
# not perform. The open-brace form's `return e;` on the next line is matched by a
# tiny two-line lookahead in lint_file. Any other statement in the block (a log
# call, a defer, a translated/other return) means it is doing real work — not a
# match.
NOOP_CATCH_SAMELINE = re.compile(r"catch\s*\|\s*(\w+)\s*\|\s*\{?\s*return\s+(\w+)\s*;")
NOOP_CATCH_OPEN = re.compile(r"catch\s*\|\s*(\w+)\s*\|\s*\{\s*$")
RETURN_ONLY = re.compile(r"^\s*return\s+(\w+)\s*;\s*$")

# camelCase enum tags. Zig names enum members snake_case (sibling enums do), but
# CAMEL_FIELD_OR_PARAM can't see a bare tag (no `:` type annotation). We track
# `enum {` / `enum(T) {` bodies by brace depth and flag a camelCase bare tag at
# the body's own depth. Deliberately NOT tracked: `union(enum)` bodies (their
# `enum` sits inside `(...)`, and members carry payload types) and `error {}`
# sets (no `enum` keyword) — both avoid false positives. A method nested in an
# enum is skipped (its body sits below the tag depth). Single-line enum bodies
# are a tolerated false-negative. Literal contents are blanked before counting
# (see blank_literals) so format strings like "{s}" cannot skew the depth.
ENUM_BODY_OPEN = re.compile(r"\benum\b\s*(?:\([^)]*\))?\s*\{")
ENUM_TAG_CAMEL = re.compile(r"^\s*([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)\s*(?:,|=[^=]|$)")
# One left-to-right alternation so whichever literal opens first wins: a char
# literal `'"'` is not misread as the start of a string, and vice versa.
_LITERAL = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')


def blank_literals(line: str) -> str:
    """Blank string/char-literal (and Zig multiline-string) contents so text
    inside them cannot trip a rule or skew brace-depth tracking. Run this
    before strip_line_comment so a `//` inside a literal (`"http://..."`) does
    not cut the rest of the line off as a comment."""
    line = _LITERAL.sub(lambda m: m.group(0)[0] * 2, line)
    stripped = line.lstrip()
    if stripped.startswith("\\\\"):  # Zig multiline-string line: remainder is text
        return line[: len(line) - len(stripped)]
    return line

# A free function performing EntityId equality (`fn *Equal(... : EntityId ...)`).
# EntityId owns `eql` (src/game/data_system/types.zig); a standalone helper is a
# divergent re-implementation of a primitive that belongs on its type. Keyed on
# the EntityId parameter type so both `entityIdsEqual` and `entitiesEqual` spellings
# are caught; the promoted method is named `eql`, so it never self-triggers.
ENTITY_EQL_FN = re.compile(r"\bfn\s+\w*[Ee]qual\s*\([^)]*:\s*EntityId\b")

# (pattern, message). Matched against literal-blanked, comment-stripped code in
# every scanned file (src/ and build.zig).
FORBIDDEN_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"\bstd\.ArrayListUnmanaged\b"),
        "std.ArrayListUnmanaged is the deprecated alias; use std.ArrayList (init `= .empty`)",
    ),
    (
        re.compile(r"\busingnamespace\b"),
        "usingnamespace was removed from the language; use explicit declaration imports",
    ),
    (
        re.compile(r"@intFromEnum\s*\("),
        "@intFromEnum is deprecated in Zig 0.17; use @backingInt (`zig fmt` rewrites it)",
    ),
    (
        re.compile(r"@enumFromInt\s*\("),
        "@enumFromInt is deprecated in Zig 0.17; use @fromBackingInt(@intCast(x)) (`zig fmt` rewrites it)",
    ),
    (
        re.compile(r"\bstd\.meta\.fields\s*\("),
        "std.meta.fields is a compile error in Zig 0.17; use @typeInfo(T).<kind>.field_names/field_types "
        "or std.meta.tags(E) for enum iteration",
    ),
    (
        re.compile(r"\.dupeZ\s*\("),
        "Allocator.dupeZ is removed in Zig 0.17; use allocator.dupeSentinel(u8, bytes, 0)",
    ),
    (
        re.compile(r"\bOptimizeMode\b"),
        "std.builtin.OptimizeMode is the deprecated alias in Zig 0.17; use std.builtin.Optimize "
        "(tags .debug/.safe/.fast/.small)",
    ),
    (
        re.compile(r"@cImport\b"),
        "@cImport is removed in Zig 0.17; C headers go through build.zig's shared TranslateC step "
        "(src/platform/sdl_c.h, imported as `sdl_c`)",
    ),
    (
        re.compile(r"\s\*\*\s"),
        "the `**` array-repeat operator is removed in Zig 0.17; use @splat (prefer `var a: [N]T = @splat(x);`)",
    ),
    (
        re.compile(r"\bstd\.mem\.(?:copy|set)\s*\("),
        "std.mem.copy/set are removed; use @memcpy/@memset",
    ),
    (
        re.compile(r"\bstd\.ArrayListAligned(?:Unmanaged)?\b"),
        "std.ArrayListAligned/ArrayListAlignedUnmanaged are deprecated in Zig 0.17; use std.array_list.Aligned",
    ),
    (
        re.compile(r"\bstd\.mem\.copy(?:Forwards|Backwards)\s*\("),
        "std.mem.copyForwards/copyBackwards are deprecated in Zig 0.17; use @memmove",
    ),
    (
        re.compile(r"\bstd\.fmt\.(?:bufPrint|bufPrintSentinel|BufPrintError)\b"),
        "std.fmt.bufPrint/bufPrintSentinel/BufPrintError are deprecated in Zig 0.17; use "
        "std.mem.print/printSentinel/PrintError",
    ),
    (
        re.compile(r"\bstd\.BoundedArray\b"),
        "std.BoundedArray is removed; use a fixed array + len or std.ArrayList",
    ),
    (
        re.compile(r"\b(?:pub\s+)?const\s+k[A-Z][A-Za-z0-9]*\b"),
        "C++-style camelCase `k` constant; non-type constants are snake_case",
    ),
]

# (pattern, message). Like FORBIDDEN_PATTERNS, but applied to src/ only. The
# `@hasDecl(` prefix survives literal blanking, so `@hasDecl(T, "x")` is caught.
SRC_ONLY_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"@hasDecl\s*\("),
        "@hasDecl is banned in src/: Zig 0.17 only sees pub declarations, so gating behavior on it "
        "silently skips private hooks; make the hook required instead",
    ),
]

# A struct field or function parameter declared camelCase (`ident: Type`). Zig
# names fields/vars snake_case; callables stay camelCase but are never declared
# with a leading `ident:` type annotation. Function-pointer-typed fields (type
# contains `fn (`) are skipped because a line regex cannot tell them from
# callables; they are snake_case by convention (the vtables in `state.zig`) and
# review checks them. Data fields/params (e.g. `assetStore: AssetStore`) are
# still caught.
CAMEL_FIELD_OR_PARAM = re.compile(r"^\s*([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)\s*:")
FN_POINTER_TYPE = re.compile(r"\bfn\s*\(")

TEST_DECL = re.compile(r"^test\b")
TOP_LEVEL_CONST = re.compile(r"^const ([A-Za-z_][A-Za-z0-9_]*)\s*=")
# Names spelled inside a literal that still reference a declaration:
# `@"name"` identifiers and `@field(x, "name")` lookups.
QUOTED_DECL_REF = re.compile(r'@"([A-Za-z_][A-Za-z0-9_]*)"|@field\s*\([^,]*,\s*"([A-Za-z_][A-Za-z0-9_]*)"')


def strip_line_comment(line: str) -> str:
    idx = line.find("//")
    return line if idx < 0 else line[:idx]


def in_literal(line: str, pos: int) -> bool:
    """True when `pos` sits inside a string or char literal."""
    quote = ""
    escaped = False
    for index, char in enumerate(line):
        if index >= pos:
            break
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
    return quote != ""


def strip_code_comment(line: str) -> str:
    """Drop a `//` comment without cutting a `//` that sits inside a string or char literal."""
    quote = ""
    escaped = False
    index = 0
    while index < len(line):
        char = line[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
        elif char == "/" and index + 1 < len(line) and line[index + 1] == "/":
            return line[:index]
        index += 1
    return line


def lint_file(path: Path) -> list[tuple[str, int, str, str]]:
    issues: list[tuple[str, int, str, str]] = []
    rel = str(path.relative_to(REPO_ROOT))
    patterns = FORBIDDEN_PATTERNS + SRC_ONLY_PATTERNS if path.is_relative_to(SRC_DIR) else FORBIDDEN_PATTERNS
    nan_exempt = rel in NAN_SELF_COMPARE_EXEMPT
    in_test = False
    brace_depth = 0
    enum_body_depths: list[int] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for lineno, raw in enumerate(lines, start=1):
        # Blank literals first: stripping `//` first would cut `"http://..."` short.
        code = strip_line_comment(blank_literals(raw))

        # Track top-level `test` blocks. `zig fmt` closes top-level decls with a
        # `}` in column 0, so this state machine is exact for formatted sources.
        if TEST_DECL.match(raw):
            in_test = True
        elif raw.startswith("}"):
            in_test = False

        for pattern, message in patterns:
            if pattern.search(code):
                issues.append((rel, lineno, message, raw.strip()))

        camel = CAMEL_FIELD_OR_PARAM.match(code)
        if camel:
            after_colon = code.split(":", 1)[1]
            if not FN_POINTER_TYPE.search(after_colon):
                issues.append(
                    (rel, lineno, f"camelCase field/parameter `{camel.group(1)}`; Zig fields/params use snake_case", raw.strip())
                )

        if not nan_exempt:
            for m in NAN_SELF_COMPARE.finditer(code):
                if m.group(1) == m.group(2):
                    issues.append(
                        (
                            rel,
                            lineno,
                            f"NaN self-compare `{m.group(1)} != {m.group(1)}`; use std.math.isNan(x) "
                            "(see src/core/math.zig) — scalar NaN checks go through the stdlib helper",
                            raw.strip(),
                        )
                    )
                    break

        if ENTITY_EQL_FN.search(code):
            issues.append(
                (
                    rel,
                    lineno,
                    "free-function EntityId equality helper; use the EntityId.eql method "
                    "(src/game/data_system/types.zig) instead of a divergent copy",
                    raw.strip(),
                )
            )

        noop = NOOP_CATCH_SAMELINE.search(code)
        noop_hit = bool(noop) and noop.group(1) == noop.group(2)
        if not noop_hit:
            open_catch = NOOP_CATCH_OPEN.search(code)
            if open_catch and lineno < len(lines):
                nxt = RETURN_ONLY.match(strip_line_comment(blank_literals(lines[lineno])))
                noop_hit = bool(nxt) and nxt.group(1) == open_catch.group(1)
        if noop_hit:
            issues.append(
                (
                    rel,
                    lineno,
                    "no-op `catch |e| return e` just re-returns the error; use `try` "
                    "(a catch that only rethrows performs no cleanup/logging/translation)",
                    raw.strip(),
                )
            )

        # camelCase enum-tag check + brace-depth tracking (must run every line so
        # the depth stays correct even for lines with no other finding).
        if ENUM_BODY_OPEN.search(code):
            enum_body_depths.append(brace_depth)
        if enum_body_depths and brace_depth == enum_body_depths[-1] + 1:
            tag = ENUM_TAG_CAMEL.match(code)
            if tag:
                issues.append(
                    (rel, lineno, f"camelCase enum tag `{tag.group(1)}`; Zig enum members use snake_case", raw.strip())
                )
        for ch in code:
            if ch == "{":
                brace_depth += 1
            elif ch == "}":
                brace_depth -= 1
                if enum_body_depths and brace_depth == enum_body_depths[-1]:
                    enum_body_depths.pop()

        if CATCH_UNREACHABLE.search(code):
            allowed = in_test or HANDLE_CTOR.search(code) or ALLOW_ANNOTATION.search(raw)
            if not allowed:
                issues.append(
                    (
                        rel,
                        lineno,
                        "`catch/orelse unreachable` can swallow a recoverable failure into ReleaseFast UB; "
                        "use a sanctioned handle constructor, propagate the error, or annotate "
                        "`// lint:allow catch-unreachable: <reason>` with a non-empty reason",
                        raw.strip(),
                    )
                )

        if path.is_relative_to(SRC_DIR) and "error.SkipZigTest" in code:
            issues.append(
                (
                    rel,
                    lineno,
                    "`error.SkipZigTest` is banned under src/ (tests, benches, and smoke included)",
                    raw.strip(),
                )
            )

    codes = [strip_line_comment(blank_literals(raw)) for raw in lines]
    quoted_refs = {
        name
        for raw in lines
        for match in QUOTED_DECL_REF.finditer(raw.split("//", 1)[0])
        for name in match.groups()
        if name
    }
    for index, raw in enumerate(lines):
        decl = TOP_LEVEL_CONST.match(raw)
        if not decl or decl.group(1) in quoted_refs:
            continue
        name = re.compile(rf"\b{decl.group(1)}\b")
        if not any(name.search(code) for other, code in enumerate(codes) if other != index):
            issues.append(
                (rel, index + 1, f"unused file-scope `{decl.group(1)}`; remove the dead import or alias", raw.strip())
            )
    return issues


# Rule 9: production files and the roots that are not production (tests, benches,
# GPU smoke). Lines inside `test` blocks never count as production references.
NON_PRODUCTION_ROOTS = {"src/tests.zig", "src/benchmark_runner.zig", "src/gpu_smoke.zig", "src/gpu_smoke_impl.zig"}
# `pub` API the owner keeps in production with no production caller yet (engine surface
# for games), keyed `(path, name)` with the owner's reason. Only the owner adds entries.
OWNER_KEPT_API = {
    ("src/app/state.zig", "pass_through_overlay"): "owner 2026-10-17: engine state preset kept for games",
}
PUB_DECL = re.compile(r"^\s*pub\s+(?:inline\s+|extern\s+|export\s+)?(?:fn|const|var)\s+([A-Za-z_][A-Za-z0-9_]*)")
# Entry hooks the compiler or std looks up by name.
PUB_ENTRY_NAMES = {"main", "std_options", "panic", "root"}
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def is_production(path: Path) -> bool:
    rel = path.relative_to(REPO_ROOT).as_posix()
    # `*test_support.zig` files are test code: only `test` blocks import them, so they never
    # compile into the game, and their references never count as production use.
    return (
        rel.startswith("src/")
        and not rel.startswith("src/benchmarks/")
        and rel not in NON_PRODUCTION_ROOTS
        and not rel.endswith("test_support.zig")
    )


TOP_LEVEL_FN = re.compile(r"^(?:pub\s+)?(?:inline\s+|export\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
PUB_FN_DECL = re.compile(r"^\s*pub\s+(?:inline\s+|extern\s+|export\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
# A method: an indented non-`pub` fn (a container's member).
METHOD_DECL = re.compile(r"^\s+(?:inline\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
TOP_LEVEL_DECL = re.compile(r"^(?:pub\s+)?(?:const|var|fn|inline\s+fn)\s+([A-Za-z_][A-Za-z0-9_]*)")
TEST_HELPER_NAME = re.compile(r"(?:ForTest|WithTestBackend)$")


def production_lines(path: Path) -> tuple[list[str], list[str]]:
    """Code lines outside `test` blocks, literals blanked and comments removed: every such
    line (for declarations), and those outside test helpers too (for references). A test
    helper is a file-scope function named `*ForTest` / `*WithTestBackend` or whose body uses
    `std.testing`: only tests reach it, so its references are test code."""
    raw_lines = path.read_text(encoding="utf-8").splitlines()
    decls: list[str] = []
    in_test = False
    for raw in raw_lines:
        if TEST_DECL.match(raw):
            in_test = True
        elif raw.startswith("}") and in_test:
            in_test = False
            decls.append("")
            continue
        code = strip_line_comment(blank_literals(raw))
        quoted = " ".join(a or b for a, b in QUOTED_DECL_REF.findall(raw))
        decls.append("" if in_test else f"{code} {quoted}")
    refs = list(decls)
    index = 0
    while index < len(raw_lines):
        fn = TOP_LEVEL_FN.match(raw_lines[index])
        if not fn or raw_lines[index].rstrip().endswith("}"):
            index += 1
            continue
        end = index + 1
        while end < len(raw_lines) and not raw_lines[end].startswith("}"):
            end += 1
        body = decls[index : end + 1]
        if TEST_HELPER_NAME.search(fn.group(1)) or any("std.testing" in line for line in body):
            for line in range(index, min(end + 1, len(refs))):
                refs[line] = ""
        index = end + 1
    return decls, refs


def own_spellings(name: str, decl_line: str, ref_line: str) -> int:
    """How often a declaration line spells its own name as a reference: once, unless the
    line sits in a test helper (its references are already blanked)."""
    return len([w for w in WORD.findall(decl_line) if w == name]) if ref_line else 0


def fn_shape(decls: list[str], index: int) -> str:
    """A `fn` declaration's parameter types after the first (the receiver) and its return
    type, whitespace-normalized: implementations of one protocol (state hooks, a comptime
    enabled/disabled pair, visitors) share a shape and are served by the same call sites."""
    text = ""
    for line in decls[index : index + 40]:
        text += " " + line
        if line.rstrip().endswith("{") or line.rstrip().endswith(";"):
            break
    start = text.find("(")
    depth = 0
    end = start
    for position in range(start, len(text)):
        if text[position] in "([{":
            depth += 1
        elif text[position] in ")]}":
            depth -= 1
            if depth == 0:
                end = position
                break
    params: list[str] = []
    depth = 0
    current = ""
    for char in text[start + 1 : end]:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            params.append(current)
            current = ""
        else:
            current += char
    if current.strip():
        params.append(current)
    types = [param.split(":", 1)[1] if ":" in param else param for param in params[1:]]
    result = text[end + 1 :].rsplit("{", 1)[0]
    return " ".join(" ".join(types + ["->", result]).split())


def top_level_spans(decls: list[str]) -> list[tuple[str, int, int]]:
    """File-scope declarations as `(name, first, last)` line spans: each runs to the line
    before the next file-scope declaration."""
    starts = [(index, m.group(1)) for index, line in enumerate(decls) if (m := TOP_LEVEL_DECL.match(line))]
    spans: list[tuple[str, int, int]] = []
    for position, (index, name) in enumerate(starts):
        last = starts[position + 1][0] - 1 if position + 1 < len(starts) else len(decls) - 1
        spans.append((name, index, last))
    return spans


def test_fixture_spans(decls: list[str], refs: list[str]) -> list[tuple[int, int]]:
    """Spans of the file-scope non-`pub` declarations only tests reach: referenced from no
    line outside the spans of such declarations (themselves included). Found as the largest
    such set, by dropping every declaration a live line references until none drops."""
    spans = top_level_spans(decls)
    owner = [-1] * len(decls)
    for position, (_, first, last) in enumerate(spans):
        for line in range(first, last + 1):
            owner[line] = position
    words = [set(WORD.findall(line)) for line in refs]
    fixture = [not decls[first].lstrip().startswith("pub ") for _, first, _ in spans]
    changed = True
    while changed:
        changed = False
        for position, (name, _, _) in enumerate(spans):
            if not fixture[position]:
                continue
            for line, line_words in enumerate(words):
                if name in line_words and owner[line] != position and (owner[line] == -1 or not fixture[owner[line]]):
                    fixture[position] = False
                    changed = True
                    break
    return [(first, last) for position, (_, first, last) in enumerate(spans) if fixture[position]]


def lint_test_only_api(files: list[Path]) -> list[tuple[str, int, str, str]]:
    prod = [path for path in files if is_production(path)]
    scanned = {path: production_lines(path) for path in prod}
    lines = {path: decls for path, (decls, _) in scanned.items()}
    counts: dict[str, int] = {}
    for _, ref_lines in scanned.values():
        for code in ref_lines:
            for word in WORD.findall(code):
                counts[word] = counts.get(word, 0) + 1
    # Every production `pub fn` declaration of each name, and the spellings those
    # declaration lines contribute to `counts`.
    fn_decls: dict[str, list[tuple[Path, int]]] = {}
    fn_shapes: dict[str, set[str]] = {}
    fn_decl_spellings: dict[str, int] = {}
    for path in prod:
        decls, refs = scanned[path]
        for index, code in enumerate(decls):
            decl = PUB_FN_DECL.match(code)
            if not decl or decl.group(1) in PUB_ENTRY_NAMES:
                continue
            name = decl.group(1)
            fn_decls.setdefault(name, []).append((path, index))
            fn_shapes.setdefault(name, set()).add(fn_shape(decls, index))
            fn_decl_spellings[name] = fn_decl_spellings.get(name, 0) + own_spellings(name, code, refs[index])
    issues: list[tuple[str, int, str, str]] = []
    for path in prod:
        rel = path.relative_to(REPO_ROOT).as_posix()
        raw_lines = path.read_text(encoding="utf-8").splitlines()
        for index, code in enumerate(lines[path]):
            decl = PUB_DECL.match(code)
            if not decl or decl.group(1) in PUB_ENTRY_NAMES:
                continue
            name = decl.group(1)
            if (rel, name) in OWNER_KEPT_API:
                continue
            own = own_spellings(name, code, scanned[path][1][index])
            if counts.get(name, 0) > own:
                continue
            here = raw_lines[index]
            issues.append(
                (rel, index + 1, f"`pub {name}` has no production use (only tests or benches reach it); remove it from production", here.strip())
            )
    # A `pub fn` name declared more than once counts as used once any one of them is
    # called: flag a name with fewer production call sites than distinct declarations
    # (same-shape implementations of one protocol count once), since at least one of them
    # is unreached.
    flagged = {(rel, line) for rel, line, _, _ in issues}
    for name, sites in sorted(fn_decls.items()):
        calls = counts.get(name, 0) - fn_decl_spellings.get(name, 0)
        distinct = len(fn_shapes[name])
        if len(sites) < 2 or calls >= distinct:
            continue
        for path, index in sites:
            rel = path.relative_to(REPO_ROOT).as_posix()
            if (rel, name) in OWNER_KEPT_API or (rel, index + 1) in flagged:
                continue
            here = path.read_text(encoding="utf-8").splitlines()[index]
            issues.append(
                (rel, index + 1, f"`pub fn {name}` has {distinct} distinct declarations in production but {calls} call sites; remove the ones only tests or benches reach", here.strip())
            )
    # Non-`pub` methods are reachable only from their own file: flag one with no in-file
    # production reference. Methods of a file-scope declaration nothing in production
    # references (a test fixture) are test code.
    for path in prod:
        rel = path.relative_to(REPO_ROOT).as_posix()
        decls, refs = scanned[path]
        raw_lines = path.read_text(encoding="utf-8").splitlines()
        file_counts: dict[str, int] = {}
        for code in refs:
            for word in WORD.findall(code):
                file_counts[word] = file_counts.get(word, 0) + 1
        fixtures = test_fixture_spans(decls, refs)
        for index, code in enumerate(decls):
            method = METHOD_DECL.match(code)
            if not method or not refs[index]:
                continue
            if any(first <= index <= last for first, last in fixtures):
                continue
            name = method.group(1)
            if file_counts.get(name, 0) > own_spellings(name, code, refs[index]):
                continue
            issues.append(
                (rel, index + 1, f"method `{name}` has no production use in its file (only tests reach it); remove it from production", raw_lines[index].strip())
            )
    return issues


# Rule 11. `.perf` is any member access (`stats.perf.x`, `.perf.x`), never the `perf_counters`
# identifier or a `.perf_*` field (`_` is a word char). Resetting it to empty (`.perf = .{}`,
# dropping the counters from a compare) reads nothing and is not a hit.
PERF_REF = re.compile(r"\bruntime_perf_log\b|\bperf_counters\b|\.perf\b(?!\s*=\s*\.\{\s*\})")
# Rule 11's self-check: each line and whether it is a hit.
PERF_REF_CASES = (
    ("try expect(stats.perf.batch.ran_inline);", True),
    ("_ = .perf.batch;", True),
    ("const x = self.perf;", True),
    ("if (comptime runtime_perf_log.enabled) {}", True),
    ("behavior.perf = .{};", False),
    ("const y = stats.perf_total;", False),
    ("const z = performance.perf_counters_off;", False),
)


def check_perf_ref() -> None:
    """Fails the lint when rule 11's pattern misreads one of its self-check cases."""
    for line, hit in PERF_REF_CASES:
        if bool(PERF_REF.search(line)) != hit:
            print(f"idiom-lint: rule 11 self-check failed on `{line}` (expected {'a hit' if hit else 'no hit'})", file=sys.stderr)
            raise SystemExit(1)

# Rule 12. Layers and the dev-tool roots no layer may import.
LAYERS = ("game", "app", "render", "assets", "core", "platform")
DEV_ROOTS = {
    "src/tests.zig",
    "src/benchmark_runner.zig",
    "src/gpu_smoke.zig",
    "src/gpu_smoke_impl.zig",
}
# App files that construct a game state. Read from src/app/: Engine builds MainMenuState;
# PauseController builds PauseState. Any other app → game import is a hit.
APP_STATE_CTORS = {"src/app/engine.zig", "src/app/pause_controller.zig"}
RELATIVE_IMPORT = re.compile(r'@import\(\s*"([^"]+)"\s*\)')


def perf_check_exempt(rel: str) -> bool:
    """Bench files and `*test_support.zig` may read counters outside `test` blocks.
    Their `test` blocks are still logic tests and are scanned."""
    return rel.startswith("src/benchmarks/") or rel.endswith("test_support.zig")


def test_block_line_indexes(lines: list[str]) -> set[int]:
    """Line indexes inside top-level `test` blocks. `zig fmt` closes them with a `}` in column 0."""
    indexes: set[int] = set()
    in_test = False
    for index, raw in enumerate(lines):
        if TEST_DECL.match(raw):
            in_test = True
        elif raw.startswith("}") and in_test:
            in_test = False
            continue
        if in_test:
            indexes.add(index)
    return indexes


_TEST_ONLY_HELPER_LINES: dict[Path, frozenset[int]] = {}


def test_only_helper_line_indexes(path: Path, lines: list[str]) -> frozenset[int]:
    """Line indexes of file-scope helpers only tests reach: the same spans rule 9 treats as test
    code. Rules 11 and 13 both read them, so each file's set is computed once."""
    if path not in _TEST_ONLY_HELPER_LINES:
        _TEST_ONLY_HELPER_LINES[path] = frozenset(find_test_only_helper_lines(path, lines))
    return _TEST_ONLY_HELPER_LINES[path]


def find_test_only_helper_lines(path: Path, lines: list[str]) -> set[int]:
    if not is_production(path):
        return set()
    decls, refs = production_lines(path)
    indexes: set[int] = set()
    for first, last in test_fixture_spans(decls, refs):
        indexes.update(range(first, last + 1))
    index = 0
    while index < len(lines):
        fn = TOP_LEVEL_FN.match(lines[index])
        if not fn or lines[index].rstrip().endswith("}"):
            index += 1
            continue
        end = index + 1
        while end < len(lines) and not lines[end].startswith("}"):
            end += 1
        body = lines[index : end + 1]
        if TEST_HELPER_NAME.search(fn.group(1)) or any("std.testing" in line for line in body):
            indexes.update(range(index, end + 1))
        index = end + 1
    return indexes


def lint_test_perf(files: list[Path]) -> list[tuple[str, int, str, str]]:
    issues: list[tuple[str, int, str, str]] = []
    for path in files:
        if not path.is_relative_to(SRC_DIR):
            continue
        rel = path.relative_to(REPO_ROOT).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        checked = test_block_line_indexes(lines)
        if not perf_check_exempt(rel):
            checked |= test_only_helper_line_indexes(path, lines)
        for index in sorted(checked):
            raw = lines[index]
            code = strip_line_comment(blank_literals(raw))
            if PERF_REF.search(code):
                issues.append(
                    (
                        rel,
                        index + 1,
                        "test code references `runtime_perf_log`, `perf_counters`, or `.perf`; "
                        "tests do not read perf counters (bench code and test-support helpers outside test blocks may)",
                        raw.strip(),
                    )
                )
    return issues


def src_layer(rel: str) -> str | None:
    """The ownership layer of a `src/` path, `benchmarks` or `devroot` for those roots, else None."""
    if not rel.startswith("src/"):
        return None
    if rel in DEV_ROOTS:
        return "devroot"
    parts = rel.split("/")
    if len(parts) >= 2 and parts[1] == "benchmarks":
        return "benchmarks"
    if len(parts) >= 2 and parts[1] in LAYERS:
        return parts[1]
    return None


def resolve_src_import(path: Path, spec: str) -> str | None:
    """A relative import's `src/` path, or None when `spec` is a module name (`std`, `sdl_c`)."""
    if not (spec.startswith(".") or spec.endswith(".zig") or "/" in spec):
        return None
    target = (path.parent / spec).resolve()
    try:
        rel = target.relative_to(REPO_ROOT)
    except ValueError:
        return None
    rel_s = rel.as_posix()
    if not rel_s.startswith("src/"):
        return None
    return rel_s


def layer_name(layer: str | None, rel: str) -> str:
    if layer == "devroot":
        return "dev-tool root"
    if layer is None:
        return rel
    return layer


def import_violation(src_rel: str, target_rel: str) -> str | None:
    source = src_layer(src_rel)
    if source not in LAYERS:
        return None
    target = src_layer(target_rel)
    if source == target:
        return None
    dest = layer_name(target, target_rel)
    if target in {"devroot", "benchmarks"}:
        return f"import crosses {source} → {dest}; a layer does not import a dev-tool root"
    if source == "core" and not target_rel.startswith("src/core/"):
        return f"import crosses core → {dest}; core imports only src/core"
    if source == "platform" and not (
        target_rel.startswith("src/platform/") or target_rel.startswith("src/core/")
    ):
        return f"import crosses platform → {dest}; platform imports only src/core"
    if target == "game" and source in {"render", "assets", "core", "platform"}:
        return f"import crosses {source} → game; {source} does not import game"
    if source == "app" and target == "game" and src_rel not in APP_STATE_CTORS:
        return (
            "import crosses app → game; app imports game only to construct states "
            "(src/app/engine.zig, src/app/pause_controller.zig)"
        )
    return None


def lint_layer_imports(files: list[Path]) -> list[tuple[str, int, str, str]]:
    issues: list[tuple[str, int, str, str]] = []
    for path in files:
        if not path.is_relative_to(SRC_DIR):
            continue
        rel = path.relative_to(REPO_ROOT).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, raw in enumerate(lines):
            # Leave the import string intact. Blanking it first would erase the
            # path. Skip a `//` that sits inside a literal so it cannot hide the
            # rest of the line.
            code = strip_code_comment(raw)
            for match in RELATIVE_IMPORT.finditer(code):
                if in_literal(code, match.start()):
                    continue
                spec = match.group(1)
                target = resolve_src_import(path, spec)
                if target is None:
                    continue
                violation = import_violation(rel, target)
                if violation is None:
                    continue
                issues.append((rel, index + 1, f"import `{spec}` {violation}", raw.strip()))
    return issues


# Rule 13. A stage-config type is a struct declaring a `?usize` `[<stage>_]items_per_range`
# field (`StageControls`, `ParallelForOptions`, `BatchWorkRequest`, `Dispatch`, each system's
# `*Config`) or the `T` of a `StageThreads(T)`. Its seam fields are its `?usize`
# `[<stage>_]items_per_range` / `[<stage>_]max_worker_threads`, `?f64`
# `[<stage>_]batches_per_participant`, and `bool` `[<stage>_]adaptive` fields;
# `adaptive_tuner` and `selected_profile` are the tuner fields.
THREAD_SYSTEM_FILE = "src/app/thread_system.zig"
CONTROLS = ("items_per_range", "max_worker_threads", "batches_per_participant", "adaptive")
# Each control's declared seam-field type.
CONTROL_KINDS = {"adaptive": "bool", "batches_per_participant": "?f64"}
TUNER_FIELDS = ("adaptive_tuner", "selected_profile")
IDENT = r"[A-Za-z_]\w*"
STRUCT_DECL = re.compile(rf"\bconst\s+({IDENT})\s*=\s*(?:extern\s+|packed\s+)?struct\s*\{{")
STAGE_THREADS_TYPE = re.compile(rf"\bStageThreads\(\s*({IDENT})\s*\)")
BODY_FIELD = re.compile(rf"(?:^|[,{{\n])\s*(?:pub\s+)?({IDENT})\s*:\s*(\?usize|\?f64|bool)\b")
FN_DECL = re.compile(rf"\bfn\s+({IDENT})\s*\(")
CALL = re.compile(rf"(?<![\w@])(?:({IDENT})\s*\.\s*)?({IDENT})\s*\(")
PARAM = re.compile(rf"^\s*(?:comptime\s+|noalias\s+)?({IDENT})\s*:\s*(.+)$", re.DOTALL)
TYPE_BASE = re.compile(rf"^(?:[?*!\s]|const\b|\[\])*(?:{IDENT}\.)*({IDENT})\s*$")
LITERAL_FIELD = re.compile(rf"\.({IDENT})\s*=(?!=)\s*(.*)", re.DOTALL)
FORWARD_TERM = re.compile(rf"^(?:{IDENT}\.)*({IDENT})\.({IDENT})$")
SELECTION = rf"(?:{IDENT}\.)*(?:\w+_)?selection"
SELECTION_FORWARD = {
    "items_per_range": re.compile(
        rf"^(?:{SELECTION}(?:\.profile)?|(?:{IDENT}\.)*(?:\w+_)?shape)\.items_per_range$"
    ),
    "max_worker_threads": re.compile(rf"^{SELECTION}(?:\.profile)?\.worker_threads$"),
    "adaptive_tuner": re.compile(rf"^{SELECTION}\.active_tuner$"),
    "selected_profile": re.compile(rf"^{SELECTION}\.profile$"),
}
CONFIG_NAME = re.compile(r"^(?:\w+_)?(?:config|controls)$")


class ControlModel:
    """What rule 13 resolves across files: the stage-config types, their seam fields (name to
    control), the names declared with a stage-config type (fields, vars, params), and each
    function's stage-config parameters as `(container, parameter count, index)`."""

    def __init__(self, texts: list[str]) -> None:
        self.config_types: set[str] = set()
        self.seam_fields: dict[str, str] = {}
        structs: list[list[tuple[str, int, int]]] = []
        for text in texts:
            spans: list[tuple[str, int, int]] = []
            for decl in STRUCT_DECL.finditer(text):
                open_brace = decl.end() - 1
                close = matching_close(text, open_brace)
                spans.append((decl.group(1), open_brace, close))
                if "items_per_range" not in text[open_brace:close]:
                    continue
                fields = BODY_FIELD.findall(flatten_body(text, open_brace, close))
                if not any(kind == "?usize" and re.fullmatch(r"(?:\w+_)?items_per_range", name) for name, kind in fields):
                    continue
                self.config_types.add(decl.group(1))
                for name, kind in fields:
                    for control in CONTROLS:
                        if re.fullmatch(rf"(?:\w+_)?{control}", name) and kind == CONTROL_KINDS.get(control, "?usize"):
                            self.seam_fields[name] = control
            structs.append(spans)
            self.config_types.update(STAGE_THREADS_TYPE.findall(text))
        types = "|".join(sorted(self.config_types)) or "(?!)"
        typed = re.compile(rf"(?<![\w.])({IDENT})\s*:\s*(?:[?*\s]|const\b|\[\])*(?:{IDENT}\.)*(?:{types})\b(?!\s*\()")
        self.typed_names: set[str] = set()
        self.config_params: dict[str, list[tuple[str | None, int, int]]] = {}
        for text, spans in zip(texts, structs):
            self.typed_names.update(typed.findall(text))
            for fn in FN_DECL.finditer(text):
                open_paren = fn.end() - 1
                params = top_level_parts(text, open_paren + 1, matching_close(text, open_paren))
                for index, (_, param) in enumerate(params):
                    parsed = PARAM.match(param)
                    base = TYPE_BASE.match(parsed.group(2)) if parsed else None
                    if base and base.group(1) in self.config_types and parsed.group(1) != "self":
                        container = innermost_container(spans, fn.start())
                        self.config_params.setdefault(fn.group(1), []).append((container, len(params), index))


def innermost_container(spans: list[tuple[str, int, int]], position: int) -> str | None:
    """The struct whose body holds `position`, innermost first."""
    inside = [(start, name) for name, start, end in spans if start < position < end]
    return max(inside)[1] if inside else None


def flatten_body(text: str, open_brace: int, close: int) -> str:
    """A container body with nested bracket contents blanked, so only its own members remain."""
    out: list[str] = []
    depth = 0
    for char in text[open_brace + 1 : close]:
        if char in "([{":
            depth += 1
            out.append(" ")
        elif char in ")]}":
            depth -= 1
            out.append(" ")
        else:
            out.append(char if depth == 0 or char == "\n" else " ")
    return "".join(out)


def matching_close(text: str, open_index: int) -> int:
    """Index of the bracket closing the one at `open_index`, or len(text) when unbalanced."""
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                return index
    return len(text)


def top_level_parts(text: str, start: int, end: int) -> list[tuple[int, str]]:
    """The comma-separated parts of `text[start:end]` at bracket depth 0, with their offsets."""
    parts: list[tuple[int, str]] = []
    depth = 0
    part_start = start
    for index in range(start, end):
        char = text[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append((part_start, text[part_start:index]))
            part_start = index + 1
    if text[part_start:end].strip():
        parts.append((part_start, text[part_start:end]))
    return parts


def is_config_forward(model: ControlModel, control: str, value: str) -> bool:
    """`value` is a seam field of `control` read from a stage-config value (`config`,
    `<x>_config`, `controls`, or `<x>_controls`, declared with a stage-config type), alone or
    in an `orelse` chain."""
    for term in value.split(" orelse "):
        forward = FORWARD_TERM.match(term.strip())
        if not forward:
            return False
        owner, field = forward.groups()
        if not (CONFIG_NAME.match(owner) and owner in model.typed_names and model.seam_fields.get(field) == control):
            return False
    return True


def control_violation(model: ControlModel, field: str, value: str) -> str | None:
    """The sub-rule a seam or tuner field set to `value` breaks, or None for a forward."""
    value = " ".join(value.split())
    if field in TUNER_FIELDS:
        if SELECTION_FORWARD[field].match(value):
            return None
        source = "the selection's `active_tuner`" if field == "adaptive_tuner" else "the selection's `profile`"
        return f"13.3: `{field} = {value}` is not {source}; a dispatch runs the shape its tuner selected and records"
    control = model.seam_fields.get(field)
    if control is None:
        return None
    if is_config_forward(model, control, value):
        return None
    selection = SELECTION_FORWARD.get(control) if control != "adaptive" else None
    if selection is not None and selection.match(value):
        return None
    if control == "adaptive":
        return f"13.2: `{field} = {value}` is not a forward of a config `adaptive`; production stages stay tuned unless their config says otherwise"
    return (
        f"13.1: `{field} = {value}` is not a forward; production forwards its stage config "
        f"(`[<x>_]config.[<stage>_]{control}` or `[<x>_]controls.[<stage>_]{control}`) or its selection, "
        f"and a fixed shape is set only by tests and benches"
    )


BATCH_COUNT_MESSAGE = (
    "13.4: a forward of a config's `items_per_range` without its `batches_per_participant` "
    "forwarded from the same owner drops the batch-count control"
)


def forward_owners(value: str) -> set[str]:
    """The owners (everything before the field, `stage.config`) a forward's terms read from."""
    return {term.strip().rsplit(".", 1)[0] for term in value.split(" orelse ")}


def batch_count_dropped(range_owners: set[str], batch_values: list[str]) -> bool:
    """13.4: a range forwarded from `range_owners` with no batch count forwarded from one of
    them. A batch count set to anything but a forward is 13.1's."""
    return not any(forward_owners(value) <= range_owners for value in batch_values)


def literal_control_hits(model: ControlModel, text: str, open_brace: int) -> list[tuple[int, str]]:
    """Rule 13 hits among the fields of the stage-config literal opening at `open_brace`."""
    hits: list[tuple[int, str]] = []
    close = matching_close(text, open_brace)
    first: int | None = None
    range_owners: set[str] = set()
    batch_values: list[str] = []
    sets_batches = False
    for offset, part in top_level_parts(text, open_brace + 1, close):
        field = LITERAL_FIELD.match(part.strip())
        if not field:
            continue
        start = offset + len(part) - len(part.lstrip())
        first = start if first is None else first
        name, value = field.group(1), " ".join(field.group(2).split())
        control = model.seam_fields.get(name)
        if control == "items_per_range" and is_config_forward(model, control, value):
            range_owners |= forward_owners(value)
        if control == "batches_per_participant":
            sets_batches = True
            if is_config_forward(model, control, value):
                batch_values.append(value)
        message = control_violation(model, name, value)
        if message:
            hits.append((start, message))
    # 13.4: forwarding a config's range size but not its batch count drops that control; a
    # batch count that is not a forward is 13.1's alone.
    if range_owners and first is not None and (not sets_batches or (batch_values and batch_count_dropped(range_owners, batch_values))):
        hits.append((first, BATCH_COUNT_MESSAGE))
    return hits


def enclosing_block(text: str, position: int) -> tuple[int, int]:
    """The span of the innermost `{...}` block holding `position`, or the whole text."""
    depth = 0
    for index in range(position - 1, -1, -1):
        char = text[index]
        if char == "}":
            depth += 1
        elif char == "{":
            if depth == 0:
                return index, matching_close(text, index)
            depth -= 1
    return 0, len(text)


def statement_batch_count_hits(model: ControlModel, text: str) -> list[tuple[int, str]]:
    """13.4 on statements: a receiver's seam range set to a config forward
    (`options.items_per_range = config.items_per_range;`) with no statement in the same block
    setting the same receiver's batch count to a forward from the same owner."""
    range_fields = "|".join(sorted(name for name, control in model.seam_fields.items() if control == "items_per_range")) or "(?!)"
    batch_fields = "|".join(sorted(name for name, control in model.seam_fields.items() if control == "batches_per_participant")) or "(?!)"
    receiver = rf"(?<![\w.])({IDENT}(?:\.{IDENT}|\.\*|\[[^\]\n]*\])*)"
    hits: list[tuple[int, str]] = []
    for assign in re.finditer(rf"{receiver}\.({range_fields})\s*=(?!=)\s*([^;]*);", text):
        value = " ".join(assign.group(3).split())
        if not is_config_forward(model, "items_per_range", value):
            continue
        start, end = enclosing_block(text, assign.start())
        sibling = re.compile(rf"(?<![\w.]){re.escape(assign.group(1))}\.(?:{batch_fields})\s*=(?!=)\s*([^;]*);")
        values = (" ".join(match.group(1).split()) for match in sibling.finditer(text, start, end))
        batch_values = [batch for batch in values if is_config_forward(model, "batches_per_participant", batch)]
        if batch_count_dropped(forward_owners(value), batch_values):
            hits.append((assign.start(), BATCH_COUNT_MESSAGE))
    return hits


def literal_field_names(text: str, open_brace: int) -> set[str]:
    """The field names a struct literal opening at `open_brace` sets."""
    parts = top_level_parts(text, open_brace + 1, matching_close(text, open_brace))
    return {field.group(1) for _, part in parts if (field := LITERAL_FIELD.match(part.strip()))}


def anonymous_literal(arg: str) -> int | None:
    """Offset of the `{` of an anonymous `.{` literal argument, or None."""
    literal = re.match(r"\s*\.\{", arg)
    return literal.end() - 1 if literal else None


def dispatch_control_hits(model: ControlModel, text: str) -> list[tuple[int, str]]:
    """Rule 13 hits in code text (literals blanked, comments removed), as `(offset, message)`."""
    hits: list[tuple[int, str]] = []
    types = "|".join(sorted(model.config_types)) or "(?!)"
    # `T{`, `: T = .{`, and a function returning `T`, whose `return .{` literals are `T`'s.
    for literal in re.finditer(rf"(?<![\w.])(?:{types})\s*(?:\{{|=\s*\.\{{)", text):
        if re.search(rf"\)\s*(?:{IDENT})?!?\s*\??\s*$", text[max(0, literal.start() - 64) : literal.start()]):
            body_end = matching_close(text, literal.end() - 1)
            for ret in re.finditer(r"\breturn\s+\.\{", text[literal.end() : body_end]):
                hits.extend(literal_control_hits(model, text, literal.end() + ret.end() - 1))
            continue
        hits.extend(literal_control_hits(model, text, literal.end() - 1))
    # A literal assigned to a name declared with a stage-config type (`.controls = .{`,
    # `self.nav_controls = .{`).
    for assign in re.finditer(rf"(?<![\w])\.?(?:{IDENT}\.)*({IDENT})\s*=(?!=)\s*\.\{{", text):
        if assign.group(1) in model.typed_names:
            hits.extend(literal_control_hits(model, text, assign.end() - 1))
    # A literal argument in a stage-config parameter's position.
    for call in CALL.finditer(text):
        receiver, name = call.groups()
        decls = model.config_params.get(name)
        if not decls or re.search(r"\bfn\s*$", text[max(0, call.start() - 8) : call.start()]):
            continue
        open_paren = call.end() - 1
        args = top_level_parts(text, open_paren + 1, matching_close(text, open_paren))
        type_receiver = receiver is not None and receiver[0].isupper()
        for container, count, index in decls:
            if type_receiver and container != receiver:
                continue
            position = index if len(args) == count else index - 1 if len(args) == count - 1 else -1
            if position < 0:
                continue
            offset, arg = args[position]
            brace = anonymous_literal(arg)
            if brace is not None:
                hits.extend(literal_control_hits(model, text, offset + brace))
        # 13.3 on the owner's dispatch calls: a null tuner, or options without the selection's.
        if name == "selectBatchProfile" and args and args[0][1].strip() == "null":
            hits.append((args[0][0], "13.3: `selectBatchProfile(null, ...)` selects a shape no tuner records; pass the stage's tuner"))
        if name == "parallelForWithOptions" and args:
            offset, options = args[-1]
            brace = anonymous_literal(options)
            if brace is None:
                hits.append((offset, "13.3: `parallelForWithOptions` options must be a literal carrying the selection's `adaptive_tuner`"))
            elif "adaptive_tuner" not in literal_field_names(text, offset + brace):
                hits.append((call.start(), "13.3: `parallelForWithOptions` without the selection's `adaptive_tuner` runs a shape no tuner records"))
    # A seam or tuner field assigned in a statement (`sort_stage.items_per_range = 1;`).
    fields = "|".join(sorted(set(model.seam_fields) | set(TUNER_FIELDS)))
    statement = rf"(?<![\w.]){IDENT}(?:\.{IDENT}|\.\*|\[[^\]\n]*\])*\.({fields})\s*[-+*]?=(?!=)\s*([^;]*);"
    for assign in re.finditer(statement, text):
        message = control_violation(model, assign.group(1), assign.group(2))
        if message:
            hits.append((assign.start(), message))
    hits.extend(statement_batch_count_hits(model, text))
    return sorted(set(hits))


# Rule 13's self-check model: the seam declarations as `thread_system.zig` and the systems
# spell them.
DISPATCH_CONTROL_DECLS = """
pub const StageControls = struct {
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};
pub const ParallelForOptions = struct {
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    range_alignment_items: usize = 1,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
    selected_profile: ?AdaptiveWorkProfile = null,
};
pub const BatchWorkRequest = struct {
    item_count: usize,
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};
pub const ThreadSystemConfig = struct {
    max_worker_threads: ?usize = null,
    items_per_range: usize = 64,
};
pub const ThreadSystem = struct {
    pub fn init(allocator: Allocator, io: Io, config: ThreadSystemConfig) !ThreadSystem {}
    pub fn selectBatchProfile(self: *const ThreadSystem, adaptive_tuner: ?*AdaptiveWorkTuner, request: BatchWorkRequest) BatchSelection {}
    pub fn parallelForWithOptions(self: *ThreadSystem, item_count: usize, context: *anyopaque, job_fn: JobFn, options: ParallelForOptions) BatchStats {}
};
pub const Dispatch = struct {
    thread_system: *ThreadSystem,
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    pub fn init(thread_system: *ThreadSystem, tuner: *AdaptiveWorkTuner, controls: StageControls) Dispatch {}
};
pub const SteeringConfig = struct {
    items_per_range: ?usize = null,
    band_items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};
pub const AiConfig = struct {
    items_per_range: ?usize = null,
    separation_items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};
const ParticleUpdateConfig = struct {
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
};
const MovementThreads = StageThreads(MovementConfig);
const SteeringSystem = struct {
    nav_controls: StageControls = .{},
    pub fn update(self: *SteeringSystem, data: *DataSystem, thread_system: *ThreadSystem, config: SteeringConfig) !void {}
    fn updateParticles(self: *SteeringSystem, update_config: ParticleUpdateConfig) void {}
};
const EditThreads = struct {
    controls: StageControls = .{},
};
const CollisionSystem = struct {
    trigger_controls: StageControls = .{},
};
"""
# Each snippet and the sub-rules it hits. The hits are the production lines L2 and L3 removed
# (worldgen paint, response place, trigger emit count), the steering band translations, and
# one per context; the passes are forwards and job-context fields.
DISPATCH_CONTROL_CASES = (
    (
        "_ = thread_system.parallelForWithOptions(geom.chunkCount(), &build_context, buildProceduralChunk, .{\n"
        "    .items_per_range = 1,\n    .range_alignment_items = 1,\n    .adaptive = false,\n});",
        ("13.1", "13.2", "13.3"),
    ),
    (
        "const place_batch = threads.thread_system.parallelForWithOptions(1, &place, placeJob, .{\n"
        "    .items_per_range = 1,\n    .max_worker_threads = selection.worker_threads,\n"
        "    .range_alignment_items = 1,\n    .adaptive = false,\n});",
        ("13.1", "13.2", "13.3"),
    ),
    (
        "const count_batch = threads.thread_system.parallelForWithOptions(items, &job, emitCountJob, .{\n"
        "    .items_per_range = threads.config.items_per_range,\n"
        "    .batches_per_participant = threads.config.batches_per_participant,\n"
        "    .max_worker_threads = threads.config.max_worker_threads,\n"
        "    .range_alignment_items = collision_range_alignment_items,\n"
        "    .adaptive = threads.config.adaptive,\n    .adaptive_tuner = null,\n"
        "    .selected_profile = selection.profile,\n});",
        ("13.3",),
    ),
    ("if (stage.config.items_per_range != null) sort_stage.items_per_range = 1;", ("13.1",)),
    ("if (stage.config.items_per_range != null) claim_stage.items_per_range = 1;", ("13.1",)),
    ("const d = Dispatch.init(ts, &tuner, .{ .items_per_range = config.items_per_range orelse 1 });", ("13.1",)),
    ("splice_controls: StageControls = .{ .adaptive = false },", ("13.2",)),
    ("const controls = StageControls{ .items_per_range = 8, .max_worker_threads = workers };", ("13.1", "13.1")),
    ("options.max_worker_threads = 0;", ("13.1",)),
    ("const s = threads.selectBatchProfile(&tuner, .{ .item_count = n, .items_per_range = 1 });", ("13.1",)),
    ("const options = ParallelForOptions{ .adaptive = false };", ("13.2",)),
    ("const request = BatchWorkRequest{ .item_count = n, .max_worker_threads = 0 };", ("13.1",)),
    ("fn controls() StageControls {\n    return .{ .adaptive = false };\n}", ("13.2",)),
    ("self.nav_controls = .{ .adaptive = false, .items_per_range = 1 };", ("13.1", "13.2")),
    ("const t: EditThreads = .{ .thread_system = ts, .controls = .{ .adaptive = false } };", ("13.2",)),
    ("step.steering = try self.steering.update(data, ts, .{ .band_items_per_range = 1, .adaptive = false });", ("13.1", "13.2")),
    ("const s = MovementThreads{ .thread_system = ts, .config = .{ .items_per_range = 1 } };", ("13.1",)),
    ("const c = SteeringConfig{ .items_per_range = 1 };", ("13.1",)),
    ("_ = ts.parallelForWithOptions(n, &c, job, .{ .max_worker_threads = config.max_worker_threads });", ("13.3",)),
    ("_ = ts.parallelForWithOptions(n, &c, job, options);", ("13.3",)),
    ("const s = ts.selectBatchProfile(null, .{ .item_count = n });", ("13.3",)),
    (
        "_ = ts.parallelForWithOptions(n, &c, job, .{ .adaptive_tuner = selection.active_tuner, "
        ".selected_profile = .{ .worker_threads = 3, .items_per_range = 1 } });",
        ("13.3",),
    ),
    ("_ = Dispatch.init(ts, &t, .{ .items_per_range = fixed_config.items_per_range });", ("13.1",)),
    ("_ = Dispatch.init(ts, &t, .{ .items_per_range = config.max_items_per_range });", ("13.1",)),
    ("_ = Dispatch.init(ts, &t, .{ .adaptive = config.non_adaptive });", ("13.2",)),
    ("_ = Dispatch.init(ts, &t, .{ .max_worker_threads = config.items_per_range });", ("13.1",)),
    ("const c = SteeringConfig{ .batches_per_participant = 4.0 };", ("13.1",)),
    ("options.batches_per_participant = 2.0;", ("13.1",)),
    (
        "_ = Dispatch.init(ts, &t, .{ .items_per_range = config.items_per_range, "
        ".batches_per_participant = config.max_worker_threads });",
        ("13.1",),
    ),
    (
        "_ = Dispatch.init(ts, &t, .{ .items_per_range = config.items_per_range, "
        ".max_worker_threads = config.max_worker_threads, .adaptive = config.adaptive });",
        ("13.4",),
    ),
    ("self.nav_controls = .{ .batches_per_participant = 4.0 };", ("13.1",)),
    (
        "_ = Dispatch.init(ts, &t, .{ .items_per_range = config.items_per_range, "
        ".batches_per_participant = update_config.batches_per_participant });",
        ("13.4",),
    ),
    ("options.items_per_range = config.items_per_range;", ("13.4",)),
    (
        "{\n    options.items_per_range = config.items_per_range;\n"
        "    options.batches_per_participant = update_config.batches_per_participant;\n}",
        ("13.4",),
    ),
    (
        "{\n    options.items_per_range = config.items_per_range;\n}\n"
        "options.batches_per_participant = config.batches_per_participant;",
        ("13.4",),
    ),
    (
        "{\n    options.items_per_range = config.items_per_range;\n"
        "    options.batches_per_participant = config.batches_per_participant;\n}",
        (),
    ),
    (
        "try self.syncTriggers(data, view, .{ .thread_system = ts, .config = .{ .strips = self.strips, "
        ".items_per_range = self.trigger_threads_controls.items_per_range, "
        ".batches_per_participant = self.trigger_threads_controls.batches_per_participant } });",
        ("13.1", "13.1"),
    ),
    (
        "_ = Dispatch.init(ts, &t, .{ .items_per_range = config.items_per_range, "
        ".max_worker_threads = config.max_worker_threads, .adaptive = config.adaptive, "
        ".batches_per_participant = config.batches_per_participant });",
        (),
    ),
    (
        "const separation = Dispatch.init(thread_system, &self.separation_tuner, .{\n"
        "    .items_per_range = config.separation_items_per_range orelse config.items_per_range,\n"
        "    .batches_per_participant = config.batches_per_participant,\n"
        "    .max_worker_threads = config.max_worker_threads,\n    .adaptive = config.adaptive,\n});",
        (),
    ),
    (
        "const sort_stage = Dispatch.init(stage.thread_system, &self.grid_sort_tuner, .{\n"
        "    .items_per_range = stage.config.band_items_per_range,\n"
        "    .batches_per_participant = stage.config.batches_per_participant,\n"
        "    .max_worker_threads = stage.config.max_worker_threads,\n    .adaptive = stage.config.adaptive,\n});",
        (),
    ),
    (
        "const dispatch = Dispatch.init(thread_system, &self.adaptive_tuner, .{ .items_per_range = update_config.items_per_range, "
        ".batches_per_participant = update_config.batches_per_participant });",
        (),
    ),
    (
        "const batch = thread_system.parallelForWithOptions(n, &context, collisionGatherJob, .{\n"
        "    .max_worker_threads = selection.worker_threads,\n    .adaptive_tuner = selection.active_tuner,\n"
        "    .selected_profile = selection.profile,\n});",
        (),
    ),
    ("const s = threads.selectBatchProfile(&tuner, .{ .item_count = n, .adaptive = config.adaptive });", ()),
    ("var job = PlaneJob{ .items_per_range = selection.items_per_range, .run_count = 1 };", ()),
    (
        "try self.syncTriggers(data, view, .{ .thread_system = ts, .config = .{ .strips = self.strips, "
        ".items_per_range = self.trigger_controls.items_per_range, "
        ".max_worker_threads = self.trigger_controls.max_worker_threads, "
        ".adaptive = self.trigger_controls.adaptive, "
        ".batches_per_participant = self.trigger_controls.batches_per_participant } });",
        (),
    ),
    ("var job = AgentsJob{ .items_per_range = agent_count };", ()),
    ("job.items_per_range = selection.items_per_range;", ()),
    ("job.items_per_range = shape.items_per_range;", ()),
    ("controls: StageControls = .{},", ()),
    ("return Dispatch.init(self.thread_system, self.plan_tuner, self.controls);", ()),
    ("fn controls(config: SteeringConfig) StageControls {\n    const n = 1;\n    return .{ .adaptive = config.adaptive };\n}", ()),
    ("var threads = try ThreadSystem.init(allocator, io, .{ .max_worker_threads = 0 });", ()),
    ("step.steering = try self.steering.update(data, ts, .{});", ()),
)


def check_dispatch_controls() -> None:
    """Fails the lint when rule 13 misreads one of its self-check cases."""
    model = ControlModel([DISPATCH_CONTROL_DECLS])
    for snippet, expected in DISPATCH_CONTROL_CASES:
        found = tuple(sorted(message.split(":", 1)[0] for _, message in dispatch_control_hits(model, snippet)))
        if found != tuple(sorted(expected)):
            print(f"idiom-lint: rule 13 self-check failed on `{snippet}` (expected {expected or 'no hit'}, got {found or 'no hit'})", file=sys.stderr)
            raise SystemExit(1)


def control_scan_text(path: Path) -> str:
    """A file's code with literals blanked, comments removed, and its test blocks and the
    helpers only tests reach blanked (the seam), line count kept."""
    lines = path.read_text(encoding="utf-8").splitlines()
    seam = test_block_line_indexes(lines) | test_only_helper_line_indexes(path, lines)
    return "\n".join("" if index in seam else strip_line_comment(blank_literals(raw)) for index, raw in enumerate(lines))


def lint_dispatch_controls(files: list[Path]) -> list[tuple[str, int, str, str]]:
    prod = [path for path in files if is_production(path)]
    texts = {path: control_scan_text(path) for path in prod}
    model = ControlModel(list(texts.values()))
    issues: list[tuple[str, int, str, str]] = []
    for path in prod:
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel == THREAD_SYSTEM_FILE:
            continue
        text = texts[path]
        lines = path.read_text(encoding="utf-8").splitlines()
        for offset, message in dispatch_control_hits(model, text):
            index = text.count("\n", 0, offset)
            issues.append((rel, index + 1, message, lines[index].strip()))
    return issues


def main() -> None:
    if not SRC_DIR.is_dir():
        print(f"idiom-lint: source directory not found: {SRC_DIR}", file=sys.stderr)
        raise SystemExit(1)

    check_perf_ref()
    check_dispatch_controls()
    files = sorted(SRC_DIR.rglob("*.zig")) + [BUILD_FILE]
    issues: list[tuple[str, int, str, str]] = []
    for path in files:
        issues.extend(lint_file(path))
    issues.extend(lint_test_only_api(files))
    issues.extend(lint_test_perf(files))
    issues.extend(lint_layer_imports(files))
    issues.extend(lint_dispatch_controls(files))

    if issues:
        for rel, lineno, message, snippet in issues:
            print(f"{rel}:{lineno}: {message}\n    {snippet}", file=sys.stderr)
        print(f"\nidiom-lint: {len(issues)} issue(s) across {len(files)} files", file=sys.stderr)
        raise SystemExit(1)

    print(f"idiom-lint: {len(files)} Zig sources clean")


if __name__ == "__main__":
    main()
