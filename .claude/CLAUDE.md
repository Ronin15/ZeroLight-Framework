# Claude Code tooling

@../AGENTS.md

`AGENTS.md` (imported above) is the project guide and applies as written; its
tooling lives here in `.claude/`:

- Rules: `.claude/rules/`. `engine-design.md` loads every session; each other
  rule loads with the files its `paths:` frontmatter names.
- Agents: `.claude/agents/`. Spawn one with the Agent tool, `subagent_type` set
  to its name.
- Reports and briefs: `.claude/reports/` (gitignored).
- Workflows: `.claude/workflows/` call the same agent names (`agentType`).
- Format hook: `.claude/hooks/zig-fmt.sh` runs on `Edit`/`Write`
  (`.claude/settings.json`).
