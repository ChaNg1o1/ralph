#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage:
#   ./ralph.sh init [target_project_dir] [--force]
#   ./ralph.sh go [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N]
#   ./ralph.sh resume [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N]
#   ./ralph.sh status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
STATE_FILE="$SCRIPT_DIR/.ralph-state.json"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd) || pwd)"

print_usage() {
  cat <<'EOF'
Usage:
  ./ralph.sh init [target_project_dir] [--force]
  ./ralph.sh go [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N]
  ./ralph.sh resume [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N]
  ./ralph.sh status

Commands:
  init                 Scaffold Ralph into a target project and stop for review.
  go                   Run Ralph until complete, blocked, review required, or max iterations reached.
  resume               Alias for go.
  status               Show current PRD/progress status.

Options:
  --tool <name>        Tool to use for Ralph iterations: codex, amp, claude
  --max-iterations <n> Maximum iterations for a go/resume run
  --stagnant-limit <n> Exit as BLOCKED after N iterations without story progress
  --force              Overwrite scaffolded files during init
  --help               Show this help

Compatibility:
  A bare number still works as max iterations, and no subcommand defaults to go.
EOF
}

write_progress_file() {
  local file_path="$1"
  cat > "$file_path" <<EOF
# Ralph Progress Log
Started: $(date)
---
EOF
}

copy_template_file() {
  local source_path="$1"
  local target_path="$2"

  mkdir -p "$(dirname "$target_path")"

  if [ -e "$target_path" ] && [ "$FORCE_INIT" = false ]; then
    echo "Skip existing: $target_path"
    return
  fi

  cp "$source_path" "$target_path"
  echo "Wrote: $target_path"
}

write_project_wrapper() {
  local target_path="$1"

  if [ -e "$target_path" ] && [ "$FORCE_INIT" = false ]; then
    echo "Skip existing: $target_path"
    return
  fi

  cat > "$target_path" <<'EOF'
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ENGINE="$SCRIPT_DIR/ralph.sh"
PROJECT_ENGINE="$SCRIPT_DIR/scripts/ralph/ralph.sh"
PWD_ENGINE="$PWD/scripts/ralph/ralph.sh"
COMMAND="${1:-}"

if [ -f "$PWD_ENGINE" ]; then
  exec "$PWD_ENGINE" "$@"
fi

if [ "$COMMAND" = "init" ] && [ -f "$LOCAL_ENGINE" ]; then
  exec "$LOCAL_ENGINE" "$@"
fi

if [ -f "$PROJECT_ENGINE" ]; then
  exec "$PROJECT_ENGINE" "$@"
fi

if [ -f "$LOCAL_ENGINE" ] && [ "$SCRIPT_DIR" = "$PWD" ]; then
  exec "$LOCAL_ENGINE" "$@"
fi

echo "Error: Could not find Ralph engine."
echo "Expected either:"
echo "  $LOCAL_ENGINE"
echo "  $PROJECT_ENGINE"
echo "  $PWD_ENGINE"
exit 1
EOF

  chmod +x "$target_path"
  echo "Wrote: $target_path"
}

write_state_file() {
  local status="$1"
  local last_story_id="$2"
  local stagnant_count="$3"
  local last_reason="$4"
  local iterations_run="$5"
  local target_path="${6:-$STATE_FILE}"

  jq -n \
    --arg status "$status" \
    --arg lastStoryId "$last_story_id" \
    --arg lastReason "$last_reason" \
    --arg updatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson stagnantCount "${stagnant_count:-0}" \
    --argjson iterationsRun "${iterations_run:-0}" \
    '{
      status: $status,
      lastStoryId: $lastStoryId,
      stagnantCount: $stagnantCount,
      lastReason: $lastReason,
      iterationsRun: $iterationsRun,
      updatedAt: $updatedAt
    }' > "$target_path"
}

require_prd() {
  if [ ! -f "$PRD_FILE" ]; then
    echo "Error: Missing $PRD_FILE"
    echo "Run './ralph init' first or create scripts/ralph/prd.json."
    exit 1
  fi
}

get_branch_name() {
  jq -r '.branchName // empty' "$PRD_FILE"
}

get_total_story_count() {
  jq '(.userStories // []) | length' "$PRD_FILE"
}

get_completed_story_count() {
  jq '[ (.userStories // [])[] | select(.passes == true) ] | length' "$PRD_FILE"
}

get_pending_story_count() {
  jq '[ (.userStories // [])[] | select(.passes != true) ] | length' "$PRD_FILE"
}

get_next_story_field() {
  local field="$1"
  jq -r --arg field "$field" '
    (.userStories // [])
    | map(select(.passes != true))
    | sort_by(.priority, .id)
    | if length == 0 then "" else .[0][$field] end
  ' "$PRD_FILE"
}

show_status() {
  require_prd

  local total completed pending branch next_id next_title next_priority run_state stagnant_count last_reason iterations_run
  total="$(get_total_story_count)"
  completed="$(get_completed_story_count)"
  pending="$(get_pending_story_count)"
  branch="$(get_branch_name)"
  next_id="$(get_next_story_field "id")"
  next_title="$(get_next_story_field "title")"
  next_priority="$(get_next_story_field "priority")"

  if [ -f "$STATE_FILE" ]; then
    run_state="$(jq -r '.status // "ready"' "$STATE_FILE")"
    stagnant_count="$(jq -r '.stagnantCount // 0' "$STATE_FILE")"
    last_reason="$(jq -r '.lastReason // ""' "$STATE_FILE")"
    iterations_run="$(jq -r '.iterationsRun // 0' "$STATE_FILE")"
  else
    run_state="ready"
    stagnant_count="0"
    last_reason=""
    iterations_run="0"
  fi

  echo "Ralph status"
  echo "Project root: $PROJECT_ROOT"
  echo "Ralph dir: $SCRIPT_DIR"
  echo "Branch: ${branch:-<unset>}"
  echo "Stories: $completed/$total complete ($pending pending)"
  if [ -n "$next_id" ]; then
    echo "Next story: $next_id (priority $next_priority) - $next_title"
  else
    echo "Next story: none"
  fi
  echo "Run state: $run_state"
  echo "Stagnant iterations: $stagnant_count"
  if [ -n "$last_reason" ]; then
    echo "Last reason: $last_reason"
  fi
  echo "Iterations run in last session: $iterations_run"
  echo "PRD: $PRD_FILE"
  echo "Progress log: $PROGRESS_FILE"
}

init_project() {
  local target_root="$1"
  local target_ralph_dir="$target_root/scripts/ralph"

  mkdir -p "$target_ralph_dir" "$target_ralph_dir/archive"

  copy_template_file "$SCRIPT_DIR/ralph.sh" "$target_ralph_dir/ralph.sh"
  chmod +x "$target_ralph_dir/ralph.sh"
  write_project_wrapper "$target_root/ralph"
  copy_template_file "$SCRIPT_DIR/CODEX.md" "$target_ralph_dir/CODEX.md"
  copy_template_file "$SCRIPT_DIR/prompt.md" "$target_ralph_dir/prompt.md"
  copy_template_file "$SCRIPT_DIR/CLAUDE.md" "$target_ralph_dir/CLAUDE.md"
  copy_template_file "$SCRIPT_DIR/AGENTS.md" "$target_ralph_dir/AGENTS.md"

  if [ ! -f "$target_ralph_dir/prd.json" ] || [ "$FORCE_INIT" = true ]; then
    cp "$SCRIPT_DIR/prd.json.example" "$target_ralph_dir/prd.json"
    echo "Wrote: $target_ralph_dir/prd.json"
  else
    echo "Skip existing: $target_ralph_dir/prd.json"
  fi

  if [ ! -f "$target_ralph_dir/progress.txt" ] || [ "$FORCE_INIT" = true ]; then
    write_progress_file "$target_ralph_dir/progress.txt"
    echo "Wrote: $target_ralph_dir/progress.txt"
  else
    echo "Skip existing: $target_ralph_dir/progress.txt"
  fi

  if [ "$FORCE_INIT" = true ] || [ ! -f "$target_ralph_dir/.ralph-state.json" ]; then
    write_state_file "ready" "" 0 "init" 0 "$target_ralph_dir/.ralph-state.json"
    echo "Wrote: $target_ralph_dir/.ralph-state.json"
  else
    echo "Skip existing: $target_ralph_dir/.ralph-state.json"
  fi

  if [ ! -d "$target_root/.git" ]; then
    echo "Warning: $target_root is not a git repository yet. Ralph expects to run inside a git repo."
  fi

  cat <<EOF

Ralph scaffold complete.
Target project: $target_root
Ralph files: $target_ralph_dir

Next steps:
  1. cd "$target_root"
  2. Review scripts/ralph/prd.json and adjust it if needed
  3. Run: ./ralph go
EOF
}

archive_previous_run_if_needed() {
  if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
    local current_branch last_branch date folder_name archive_folder
    current_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")"
    last_branch="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")"

    if [ -n "$current_branch" ] && [ -n "$last_branch" ] && [ "$current_branch" != "$last_branch" ]; then
      date="$(date +%Y-%m-%d)"
      folder_name="$(echo "$last_branch" | sed 's|^ralph/||')"
      archive_folder="$ARCHIVE_DIR/$date-$folder_name"

      echo "Archiving previous run: $last_branch"
      mkdir -p "$archive_folder"
      [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$archive_folder/"
      [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$archive_folder/"
      [ -f "$STATE_FILE" ] && cp "$STATE_FILE" "$archive_folder/"
      echo "   Archived to: $archive_folder"

      write_progress_file "$PROGRESS_FILE"
      write_state_file "ready" "" 0 "branch_changed" 0
    fi
  fi
}

track_current_branch() {
  if [ -f "$PRD_FILE" ]; then
    local current_branch
    current_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")"
    if [ -n "$current_branch" ]; then
      echo "$current_branch" > "$LAST_BRANCH_FILE"
    fi
  fi
}

ensure_progress_and_state_files() {
  if [ ! -f "$PROGRESS_FILE" ]; then
    write_progress_file "$PROGRESS_FILE"
  fi

  if [ ! -f "$STATE_FILE" ]; then
    write_state_file "ready" "" 0 "initialized" 0
  fi
}

validate_tool_choice() {
  if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "codex" ]]; then
    echo "Error: Invalid tool '$TOOL'. Must be 'codex', 'amp', or 'claude'."
    exit 1
  fi
}

run_selected_tool() {
  if [[ "$TOOL" == "amp" ]]; then
    cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr
  elif [[ "$TOOL" == "claude" ]]; then
    claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr
  else
    {
      echo "# Ralph Execution Context"
      echo "Project root: $PROJECT_ROOT"
      echo "Ralph directory: $SCRIPT_DIR"
      echo "PRD file: $PRD_FILE"
      echo "Progress file: $PROGRESS_FILE"
      echo ""
      cat "$SCRIPT_DIR/CODEX.md"
    } | codex exec -C "$PROJECT_ROOT" -s danger-full-access 2>&1 | tee /dev/stderr
  fi
}

run_go() {
  require_prd
  validate_tool_choice
  archive_previous_run_if_needed
  track_current_branch
  ensure_progress_and_state_files

  local pending_before pending_after next_story_before next_story_after stagnant_count iterations_run reason output
  stagnant_count="$(jq -r '.stagnantCount // 0' "$STATE_FILE" 2>/dev/null || echo "0")"
  iterations_run=0

  if [ "$(get_pending_story_count)" -eq 0 ]; then
    write_state_file "complete" "" 0 "all_stories_passed" 0
    echo "Ralph already complete."
    echo "<promise>COMPLETE</promise>"
    exit 0
  fi

  write_state_file "running" "$(get_next_story_field "id")" "$stagnant_count" "starting" 0

  echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS - Stagnant limit: $STAGNANT_LIMIT"

  for i in $(seq 1 "$MAX_ITERATIONS"); do
    iterations_run="$i"
    pending_before="$(get_pending_story_count)"
    next_story_before="$(get_next_story_field "id")"

    echo ""
    echo "==============================================================="
    echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
    echo "==============================================================="
    echo "  Current story: ${next_story_before:-<none>}"

    output="$(run_selected_tool || true)"

    pending_after="$(get_pending_story_count)"
    next_story_after="$(get_next_story_field "id")"

    if echo "$output" | grep -q "<promise>COMPLETE</promise>"; then
      write_state_file "complete" "" 0 "tool_reported_complete" "$iterations_run"
      echo ""
      echo "Ralph completed all tasks."
      exit 0
    fi

    if echo "$output" | grep -q "<promise>REVIEW_REQUIRED</promise>"; then
      write_state_file "review_required" "$next_story_after" "$stagnant_count" "tool_requested_review" "$iterations_run"
      echo ""
      echo "Ralph requires human review before continuing."
      exit 3
    fi

    if echo "$output" | grep -q "<promise>BLOCKED</promise>"; then
      write_state_file "blocked" "$next_story_after" "$stagnant_count" "tool_reported_blocked" "$iterations_run"
      echo ""
      echo "Ralph is blocked and stopped."
      exit 2
    fi

    if [ "$pending_after" -eq 0 ]; then
      write_state_file "complete" "" 0 "all_stories_passed" "$iterations_run"
      echo ""
      echo "Ralph completed all tasks."
      exit 0
    fi

    if [ "$pending_after" -lt "$pending_before" ]; then
      stagnant_count=0
      reason="story_completed"
    elif [ -n "$next_story_before" ] && [ "$next_story_before" = "$next_story_after" ]; then
      stagnant_count=$((stagnant_count + 1))
      reason="no_progress_on_${next_story_after}"
    else
      stagnant_count=0
      reason="story_changed"
    fi

    write_state_file "running" "$next_story_after" "$stagnant_count" "$reason" "$iterations_run"

    if [ "$stagnant_count" -ge "$STAGNANT_LIMIT" ]; then
      write_state_file "blocked" "$next_story_after" "$stagnant_count" "stagnant_limit_reached" "$iterations_run"
      echo ""
      echo "Ralph blocked: story ${next_story_after:-<unknown>} made no progress for $stagnant_count iterations."
      exit 2
    fi

    echo "Iteration $i complete. Pending stories: $pending_after. Stagnant count: $stagnant_count."
    sleep 2
  done

  write_state_file "max_iterations_reached" "$(get_next_story_field "id")" "$stagnant_count" "max_iterations_reached" "$MAX_ITERATIONS"
  echo ""
  echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
  echo "Check $PROGRESS_FILE for status."
  exit 4
}

TOOL="codex"
MAX_ITERATIONS=10
STAGNANT_LIMIT=3
FORCE_INIT=false
COMMAND="go"
TARGET_DIR=""

if [[ $# -gt 0 ]]; then
  case "$1" in
    init|go|resume|status)
      COMMAND="$1"
      shift
      ;;
    --help|-h|help)
      print_usage
      exit 0
      ;;
  esac
fi

case "$COMMAND" in
  init)
    TARGET_DIR="$(pwd)"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --force)
          FORCE_INIT=true
          shift
          ;;
        --help|-h|help)
          print_usage
          exit 0
          ;;
        *)
          TARGET_DIR="$1"
          shift
          ;;
      esac
    done

    init_project "$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")"
    ;;
  status)
    show_status
    ;;
  go|resume)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --tool)
          TOOL="$2"
          shift 2
          ;;
        --tool=*)
          TOOL="${1#*=}"
          shift
          ;;
        --max-iterations)
          MAX_ITERATIONS="$2"
          shift 2
          ;;
        --max-iterations=*)
          MAX_ITERATIONS="${1#*=}"
          shift
          ;;
        --stagnant-limit)
          STAGNANT_LIMIT="$2"
          shift 2
          ;;
        --stagnant-limit=*)
          STAGNANT_LIMIT="${1#*=}"
          shift
          ;;
        --help|-h|help)
          print_usage
          exit 0
          ;;
        *)
          if [[ "$1" =~ ^[0-9]+$ ]]; then
            MAX_ITERATIONS="$1"
          else
            echo "Error: Unknown argument '$1'"
            print_usage
            exit 1
          fi
          shift
          ;;
      esac
    done

    run_go
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
