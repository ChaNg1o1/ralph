# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Codex CLI](https://developers.openai.com/codex), [Amp](https://ampcode.com), or [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- One of the following AI coding tools installed and authenticated:
  - [Codex CLI](https://developers.openai.com/codex) (default in this fork)
  - [Amp CLI](https://ampcode.com)
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Quick Init

From this Ralph repository, scaffold Ralph into any target project:

```bash
cd /path/to/ralph
./ralph init /path/to/your-project
```

If you want to use `ralph init` and `ralph status` without `./`, add the wrapper to your `PATH` once:

```bash
ln -sf /path/to/ralph/ralph ~/.local/bin/ralph
# or on macOS with Homebrew's default user bin:
ln -sf /path/to/ralph/ralph /opt/homebrew/bin/ralph
```

This creates:

- `ralph`
- `scripts/ralph/ralph.sh`
- `scripts/ralph/CODEX.md`
- `scripts/ralph/prompt.md`
- `scripts/ralph/CLAUDE.md`
- `scripts/ralph/AGENTS.md`
- `scripts/ralph/prd.json`
- `scripts/ralph/progress.txt`

Use `--force` to overwrite existing scaffolded files:

```bash
./ralph init /path/to/your-project --force
```

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph .
cp /path/to/ralph/ralph.sh scripts/ralph/

# Copy the prompt template for your AI tool of choice:
cp /path/to/ralph/CODEX.md scripts/ralph/CODEX.md      # For Codex
# OR
cp /path/to/ralph/prompt.md scripts/ralph/prompt.md    # For Amp
# OR
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md    # For Claude Code

chmod +x ralph scripts/ralph/ralph.sh
```

### Option 2: Install skills globally

Copy the skills to your Codex, Amp, or Claude config for use across all projects:

For Codex
```bash
cp -r skills/prd ~/.codex/skills/
cp -r skills/ralph ~/.codex/skills/
```

For AMP
```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
```

For Claude Code (manual)
```bash
cp -r skills/prd ~/.claude/skills/
cp -r skills/ralph ~/.claude/skills/
```

Restart Codex after installing skills into `~/.codex/skills/`.

### Option 3: Use as Claude Code Marketplace

Add the Ralph marketplace to Claude Code:

```bash
/plugin marketplace add snarktank/ralph
```

Then install the skills:

```bash
/plugin install ralph-skills@ralph-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Run the Ralph workflow (`init`, `go`, `resume`, `status`) and still supports PRD-to-JSON conversion

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"
- "run ralph init", "run ralph go", "show ralph status", "resume ralph"

### Configure Amp auto-handoff (recommended)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Ralph to handle large stories that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Use the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

In Codex, the Ralph skill is the workflow entry point. It can still convert a markdown PRD into Ralph JSON:

```
Use the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

If you installed the skill into Codex, the same skill is also how you drive the loop:

```text
$ralph init /path/to/your-project
$ralph status
$ralph go
$ralph resume
```

### 3. Review, Then Run Ralph

After `init`, review `scripts/ralph/prd.json` first. Once it looks right, start the loop:

```bash
# Show current state
./ralph status

# Using Codex (default)
./ralph go

# Using Amp
./ralph go --tool amp --max-iterations 10

# Using Claude Code
./ralph go --tool claude --max-iterations 10

# Resume after a stop condition
./ralph resume
```

Default is 10 iterations. Use `--tool codex`, `--tool amp`, or `--tool claude` to select your AI coding tool.

Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. Pick the highest priority story where `passes: false`
3. Implement that single story
4. Run quality checks (typecheck, tests)
5. Commit if checks pass
6. Update `prd.json` to mark story as `passes: true`
7. Append learnings to `progress.txt`
8. Repeat until all stories pass or max iterations reached

`ralph go` stops with one of these outcomes:

- `COMPLETE`: all stories are done
- `REVIEW_REQUIRED`: a human should check something, then continue with `./ralph resume`
- `BLOCKED`: the same story is stuck or a prerequisite is missing
- `MAX_ITERATIONS_REACHED`: it hit the configured iteration cap

## Key Files

| File | Purpose |
|------|---------|
| `ralph` | User-facing command wrapper for `init`, `go`, `resume`, and `status` |
| `ralph.sh` | The bash loop that spawns fresh AI instances (supports `--tool codex`, `--tool amp`, or `--tool claude`) |
| `CODEX.md` | Prompt template for Codex |
| `prompt.md` | Prompt template for Amp |
| `CLAUDE.md` | Prompt template for Claude Code |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs (works with Codex, Amp, and Claude Code) |
| `skills/ralph/` | Skill for running `init`, `go`, `resume`, and `status` in Codex or converting PRDs to JSON |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Codex, Amp, or Claude Code) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using available browser tooling" in acceptance criteria. For Codex runs, prefer `autoglm-browser-agent` first when it is installed and configured. Otherwise use whatever browser automation is available, such as `dev-browser`, Codex Playwright, or an MCP browser tool.

### Stop Condition

When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

Check current state:

```bash
# Ralph summary
./ralph status

# See which stories are done
cat scripts/ralph/prd.json | jq '.userStories[] | {id, title, passes}'

# See learnings from previous iterations
cat scripts/ralph/progress.txt

# Check git history
git log --oneline -10
```

Recreate or fill in missing Ralph files for the current project:

```bash
./ralph init .
```

## Customizing the Prompt

After copying `CODEX.md` (for Codex), `prompt.md` (for Amp), or `CLAUDE.md` (for Claude Code) to your project, customize it for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Codex CLI documentation](https://developers.openai.com/codex)
- [Amp documentation](https://ampcode.com/manual)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
