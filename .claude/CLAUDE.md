# Claude Code tooling

`AGENTS.md` is the shared project guide and applies as written. Its `.grok/`
tooling has Claude Code equivalents here; read each `.grok/` path in it as the
`.claude/` one below.

- Rules: `.claude/rules/` mirrors `.grok/rules/` (same text, plus `paths:`
  frontmatter so each loads with the files it guards). A rule edit lands in
  both copies in the same change.
- Agents: `.claude/agents/` mirrors `.grok/agents/` bodies with Claude tool
  lists. Spawn one with the Agent tool, `subagent_type` set to its name, in
  place of `spawn_subagent`.
- Reports and briefs: `.claude/reports/` (gitignored), in place of
  `.grok/reports/`.
- Workflows: `.claude/workflows/` call the same agent names (`agentType`).
- Format hook: `.claude/hooks/zig-fmt.sh` runs on `Edit`/`Write`
  (`.claude/settings.json`).
- `.claude/` stays untracked so it never interferes with the Grok tree.
