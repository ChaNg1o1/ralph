# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Codex, Amp, or Claude Code) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Commands

```bash
# Scaffold Ralph into another project
./ralph init /path/to/project

# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Show Ralph status
./ralph status

# Run Ralph with Codex (default)
./ralph go

# Resume a stopped run
./ralph resume

# Run Ralph with Amp
./ralph go --tool amp --max-iterations 10

# Run Ralph with Claude Code
./ralph go --tool claude --max-iterations 10

# Run Ralph with Codex explicitly
./ralph go --tool codex --max-iterations 10
```

## Key Files

- `ralph` - User-facing command wrapper; runs local `ralph.sh` or `scripts/ralph/ralph.sh`
- `ralph.sh` - The underlying loop engine and CLI implementation
- `ralph init` - Scaffolds the project root `./ralph` command plus `scripts/ralph/` files
- `prompt.md` - Instructions given to each AMP instance
- `CLAUDE.md` - Instructions given to each Claude Code instance
- `CODEX.md` - Instructions given to each Codex iteration
- `prd.json.example` - Example PRD format
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## Flowchart

The `flowchart/` directory contains an interactive visualization built with React Flow. It's designed for presentations - click through to reveal each step with animations.

To run locally:
```bash
cd flowchart
npm install
npm run dev
```

## Patterns

- Each iteration spawns a fresh AI instance (Codex, Amp, or Claude Code) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- For browser verification in Codex runs, prefer `autoglm-browser-agent` before other browser tooling
- `ralph go` should stop with a clear state: complete, blocked, review required, or max iterations reached
- Always update AGENTS.md with discovered patterns for future iterations
