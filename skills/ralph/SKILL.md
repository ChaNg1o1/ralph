---
name: ralph
description: "Manage the Ralph workflow in Codex. Use for `$ralph init`, `$ralph go`, `$ralph resume`, `$ralph status`, or when converting an existing PRD into Ralph's `prd.json` format."
user-invocable: true
---

# Ralph Workflow Skill

This skill is the Codex-facing entry point for Ralph.

Use it for two kinds of tasks:

1. **Workflow commands**
   - `$ralph init`
   - `$ralph go`
   - `$ralph resume`
   - `$ralph status`
2. **Legacy PRD conversion**
   - "convert this PRD to Ralph format"
   - "create `prd.json` from this spec"

## Command Routing

Prefer the bundled script:

```bash
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
"$CODEX_HOME/skills/ralph/scripts/ralph-skill.sh" <command> [args]
```

### `init`

When the user asks for `$ralph init`:

1. Run:

```bash
"$CODEX_HOME/skills/ralph/scripts/ralph-skill.sh" init
```

Or with an explicit project path:

```bash
"$CODEX_HOME/skills/ralph/scripts/ralph-skill.sh" init /path/to/project
```

2. This should scaffold:
   - `./ralph`
   - `scripts/ralph/ralph.sh`
   - `scripts/ralph/CODEX.md`
   - `scripts/ralph/prompt.md`
   - `scripts/ralph/CLAUDE.md`
   - `scripts/ralph/AGENTS.md`
   - `scripts/ralph/prd.json`
   - `scripts/ralph/progress.txt`
   - `scripts/ralph/.ralph-state.json`

3. Stop after scaffolding. Do **not** run the loop during `init`.
4. Tell the user to review `scripts/ralph/prd.json` before running `go`.

### `go`

When the user asks for `$ralph go`:

1. Run:

```bash
"$CODEX_HOME/skills/ralph/scripts/ralph-skill.sh" go
```

2. If the user specifies a tool or iteration cap, pass them through.
3. Explain the stop condition in the result:
   - `COMPLETE`
   - `REVIEW_REQUIRED`
   - `BLOCKED`
   - `MAX_ITERATIONS_REACHED`

### `resume`

When the user asks for `$ralph resume`, run:

```bash
"$CODEX_HOME/skills/ralph/scripts/ralph-skill.sh" resume
```

### `status`

When the user asks for `$ralph status`, run:

```bash
"$CODEX_HOME/skills/ralph/scripts/ralph-skill.sh" status
```

Report the current story, completion count, and run state.

## Browser Verification

For Codex-driven UI verification, prefer:

1. `autoglm-browser-agent`
2. Other browser tooling such as Playwright, `dev-browser`, or an MCP browser tool

## Legacy PRD Conversion Mode

If the user explicitly asks to convert an existing PRD or spec into Ralph JSON, update `scripts/ralph/prd.json` directly.

Conversion rules:

- Break work into stories small enough for one Ralph iteration.
- Order stories by dependency: schema, backend, UI, aggregation.
- Every story must include `"Typecheck passes"`.
- UI stories must include `"Verify in browser using available browser tooling"`.
- Set all stories to `passes: false`.
- Use `ralph/<feature-name>` for `branchName`.

Minimal output shape:

```json
{
  "project": "ProjectName",
  "branchName": "ralph/feature-name",
  "description": "Short feature summary",
  "userStories": []
}
```

If `scripts/ralph/prd.json` does not exist yet, run `init` first.
