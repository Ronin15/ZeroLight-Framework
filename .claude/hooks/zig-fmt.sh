#!/usr/bin/env bash
# PostToolUse hook: run `zig fmt` on a .zig/.zon file Claude just edited or wrote.
# Formatting failures (e.g. mid-edit syntax errors) are left for `zig build check`.
set -u
file_path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
case "$file_path" in
  *.zig | *.zon) ;;
  *) exit 0 ;;
esac
case "$file_path" in
  */zig-out/* | */.zig-cache/*) exit 0 ;;
esac
[ -f "$file_path" ] || exit 0
command -v zig >/dev/null 2>&1 || exit 0
zig fmt "$file_path" >/dev/null 2>&1 || true
exit 0
