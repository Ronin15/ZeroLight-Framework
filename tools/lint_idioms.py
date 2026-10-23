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


def test_only_helper_line_indexes(path: Path, lines: list[str]) -> set[int]:
    """Line indexes of file-scope helpers only tests reach: the same spans rule 9 treats as test code."""
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


def main() -> None:
    if not SRC_DIR.is_dir():
        print(f"idiom-lint: source directory not found: {SRC_DIR}", file=sys.stderr)
        raise SystemExit(1)

    check_perf_ref()
    files = sorted(SRC_DIR.rglob("*.zig")) + [BUILD_FILE]
    issues: list[tuple[str, int, str, str]] = []
    for path in files:
        issues.extend(lint_file(path))
    issues.extend(lint_test_only_api(files))
    issues.extend(lint_test_perf(files))
    issues.extend(lint_layer_imports(files))

    if issues:
        for rel, lineno, message, snippet in issues:
            print(f"{rel}:{lineno}: {message}\n    {snippet}", file=sys.stderr)
        print(f"\nidiom-lint: {len(issues)} issue(s) across {len(files)} files", file=sys.stderr)
        raise SystemExit(1)

    print(f"idiom-lint: {len(files)} Zig sources clean")


if __name__ == "__main__":
    main()
