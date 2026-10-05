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

Scans every `src/**/*.zig` file plus `build.zig`. Rules in SRC_ONLY_PATTERNS
apply to `src/` only. All rules match code with string/char-literal contents
blanked and `//` comments removed, so text inside literals never trips a rule.

Run via `zig build idiom-lint` (also part of `zig build verify`).
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
        re.compile(r"\bstd\.BoundedArray\b"),
        "std.BoundedArray is removed; use a fixed array + len or std.ArrayList",
    ),
    (
        re.compile(r"\b(?:pub\s+)?const\s+k[A-Z][A-Za-z0-9]*\b"),
        "C++-style camelCase `k` constant; use k_snake_case to match the codebase convention",
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
# contains `fn (`) are exempt: naming them for the callable they store is a
# defensible convention and flagging them would push toward snake_case function
# names. Data fields/params (e.g. `assetStore: AssetStore`) are still caught.
CAMEL_FIELD_OR_PARAM = re.compile(r"^\s*([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)\s*:")
FN_POINTER_TYPE = re.compile(r"\bfn\s*\(")

TEST_DECL = re.compile(r"^test\b")


def strip_line_comment(line: str) -> str:
    idx = line.find("//")
    return line if idx < 0 else line[:idx]


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
    return issues


def main() -> None:
    if not SRC_DIR.is_dir():
        print(f"idiom-lint: source directory not found: {SRC_DIR}", file=sys.stderr)
        raise SystemExit(1)

    files = sorted(SRC_DIR.rglob("*.zig")) + [BUILD_FILE]
    issues: list[tuple[str, int, str, str]] = []
    for path in files:
        issues.extend(lint_file(path))

    if issues:
        for rel, lineno, message, snippet in issues:
            print(f"{rel}:{lineno}: {message}\n    {snippet}", file=sys.stderr)
        print(f"\nidiom-lint: {len(issues)} issue(s) across {len(files)} files", file=sys.stderr)
        raise SystemExit(1)

    print(f"idiom-lint: {len(files)} Zig sources clean")


if __name__ == "__main__":
    main()
