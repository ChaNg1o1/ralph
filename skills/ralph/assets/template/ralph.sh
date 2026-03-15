#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage:
#   ./ralph.sh init [target_project_dir] [--force]
#   ./ralph.sh go [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N] [--idle-timeout N]
#   ./ralph.sh resume [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N] [--idle-timeout N]
#   ./ralph.sh status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
STATE_FILE="$SCRIPT_DIR/.ralph-state.json"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd) || pwd)"
RUN_ACTIVE=false
CURRENT_STORY_ID=""
CURRENT_STAGNANT_COUNT=0
CURRENT_REASON=""
CURRENT_ITERATIONS_RUN=0

print_usage() {
  cat <<'EOF'
Usage:
  ./ralph.sh init [target_project_dir] [--force]
  ./ralph.sh go [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N] [--idle-timeout N]
  ./ralph.sh resume [--tool codex|amp|claude] [--max-iterations N] [--stagnant-limit N] [--idle-timeout N]
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
  --idle-timeout <n>   Stop the active tool after N seconds without stdout/stderr output (0 disables)
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

write_runtime_gitignore() {
  local target_path="$1"

  mkdir -p "$(dirname "$target_path")"

  if [ -e "$target_path" ] && [ "$FORCE_INIT" = false ]; then
    echo "Skip existing: $target_path"
    return
  fi

  cat > "$target_path" <<'EOF'
.last-branch
.ralph-state.json
EOF

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

set_current_run_context() {
  CURRENT_STORY_ID="${1:-}"
  CURRENT_STAGNANT_COUNT="${2:-0}"
  CURRENT_REASON="${3:-}"
  CURRENT_ITERATIONS_RUN="${4:-0}"
}

persist_current_run_state() {
  local status="$1"
  write_state_file "$status" "$CURRENT_STORY_ID" "$CURRENT_STAGNANT_COUNT" "$CURRENT_REASON" "$CURRENT_ITERATIONS_RUN"
}

clear_current_run_context() {
  RUN_ACTIVE=false
  set_current_run_context "" 0 "" 0
}

terminate_active_children() {
  pkill -TERM -P $$ 2>/dev/null || true
  sleep 1
  pkill -KILL -P $$ 2>/dev/null || true
}

finish_run() {
  local status="$1"
  local exit_code="$2"
  persist_current_run_state "$status"
  clear_current_run_context
  exit "$exit_code"
}

handle_run_signal() {
  local signal_name="$1"
  local exit_code="$2"
  local lowered_signal

  lowered_signal="$(printf '%s' "$signal_name" | tr '[:upper:]' '[:lower:]')"

  if [ "$RUN_ACTIVE" = true ]; then
    terminate_active_children
    CURRENT_REASON="signal_${lowered_signal}"
    persist_current_run_state "interrupted"
    clear_current_run_context
  fi

  exit "$exit_code"
}

handle_run_exit() {
  local exit_code="$1"

  if [ "$RUN_ACTIVE" = true ] && [ "$exit_code" -ne 0 ]; then
    if [ -z "$CURRENT_REASON" ]; then
      CURRENT_REASON="unexpected_exit"
    fi
    persist_current_run_state "interrupted"
    clear_current_run_context
  fi
}

trap 'handle_run_signal INT 130' INT
trap 'handle_run_signal TERM 143' TERM
trap 'handle_run_exit $?' EXIT

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
  write_runtime_gitignore "$target_ralph_dir/.gitignore"

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

build_selected_tool_command_json() {
  if [[ "$TOOL" == "amp" ]]; then
    jq -cn '["amp", "--dangerously-allow-all"]'
  elif [[ "$TOOL" == "claude" ]]; then
    jq -cn '["claude", "--dangerously-skip-permissions", "--print"]'
  else
    jq -cn --arg projectRoot "$PROJECT_ROOT" '["codex", "exec", "-C", $projectRoot, "-s", "danger-full-access"]'
  fi
}

write_selected_tool_input() {
  local input_file="$1"

  if [[ "$TOOL" == "amp" ]]; then
    cat "$SCRIPT_DIR/prompt.md" > "$input_file"
  elif [[ "$TOOL" == "claude" ]]; then
    cat "$SCRIPT_DIR/CLAUDE.md" > "$input_file"
  else
    {
      echo "# Ralph Execution Context"
      echo "Project root: $PROJECT_ROOT"
      echo "Ralph directory: $SCRIPT_DIR"
      echo "PRD file: $PRD_FILE"
      echo "Progress file: $PROGRESS_FILE"
      echo ""
      cat "$SCRIPT_DIR/CODEX.md"
    } > "$input_file"
  fi
}

run_selected_tool_with_watchdog() {
  local output_file="$1"
  local meta_file="$2"
  local input_file command_json

  input_file="$(mktemp "${TMPDIR:-/tmp}/ralph-input.XXXXXX")"
  write_selected_tool_input "$input_file"
  command_json="$(build_selected_tool_command_json)"

  python3 - "$IDLE_TIMEOUT" "$output_file" "$meta_file" "$input_file" "$command_json" <<'PY'
import json
import os
import select
import signal
import subprocess
import sys
import time

idle_timeout = int(sys.argv[1])
output_path = sys.argv[2]
meta_path = sys.argv[3]
input_path = sys.argv[4]
command = json.loads(sys.argv[5])

timed_out = False
last_output_at = time.monotonic()
exit_code = 0
proc = None

def forward_signal(signum, _frame):
    global proc
    if proc is not None and proc.poll() is None:
        os.killpg(proc.pid, signum)
    raise SystemExit(128 + signum)

signal.signal(signal.SIGINT, forward_signal)
signal.signal(signal.SIGTERM, forward_signal)

with open(input_path, "rb") as stdin_handle, open(output_path, "wb") as output_handle:
    try:
        proc = subprocess.Popen(
            command,
            stdin=stdin_handle,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except OSError as exc:
        exit_code = 127
        message = f"Failed to start {' '.join(command)}: {exc}\n".encode()
        output_handle.write(message)
        output_handle.flush()
        sys.stdout.buffer.write(message)
        sys.stdout.buffer.flush()
        proc = None

    if proc is not None:
        stdout_fd = proc.stdout.fileno()

        while True:
            timeout = None
            if idle_timeout > 0:
                timeout = max(0, idle_timeout - (time.monotonic() - last_output_at))

            ready, _, _ = select.select([stdout_fd], [], [], timeout)

            if ready:
                chunk = os.read(stdout_fd, 4096)
                if chunk:
                    last_output_at = time.monotonic()
                    output_handle.write(chunk)
                    output_handle.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                elif proc.poll() is not None:
                    break
            else:
                if proc.poll() is None and idle_timeout > 0:
                    timed_out = True
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait()
                    break

            if proc.poll() is not None and not ready:
                break

        while True:
            chunk = os.read(stdout_fd, 4096)
            if not chunk:
                break
            output_handle.write(chunk)
            output_handle.flush()
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

        exit_code = proc.wait()

with open(meta_path, "w", encoding="utf-8") as meta_handle:
    json.dump(
        {
            "command": command,
            "exitCode": exit_code,
            "timedOut": timed_out,
            "idleTimeoutSeconds": idle_timeout,
        },
        meta_handle,
    )
PY

  rm -f "$input_file"
}

run_go() {
  require_prd
  validate_tool_choice
  archive_previous_run_if_needed
  track_current_branch
  ensure_progress_and_state_files

  local pending_before pending_after next_story_before next_story_after stagnant_count iterations_run reason output
  local output_file meta_file child_exit_code child_timed_out
  stagnant_count="$(jq -r '.stagnantCount // 0' "$STATE_FILE" 2>/dev/null || echo "0")"
  iterations_run=0

  if [ "$(get_pending_story_count)" -eq 0 ]; then
    set_current_run_context "" 0 "all_stories_passed" 0
    echo "Ralph already complete."
    echo "<promise>COMPLETE</promise>"
    finish_run "complete" 0
  fi

  RUN_ACTIVE=true
  set_current_run_context "$(get_next_story_field "id")" "$stagnant_count" "starting" 0
  persist_current_run_state "running"

  echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS - Stagnant limit: $STAGNANT_LIMIT - Idle timeout: $IDLE_TIMEOUT"

  for i in $(seq 1 "$MAX_ITERATIONS"); do
    iterations_run="$i"
    pending_before="$(get_pending_story_count)"
    next_story_before="$(get_next_story_field "id")"
    set_current_run_context "$next_story_before" "$stagnant_count" "running_iteration" "$iterations_run"
    persist_current_run_state "running"

    echo ""
    echo "==============================================================="
    echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
    echo "==============================================================="
    echo "  Current story: ${next_story_before:-<none>}"

    output_file="$(mktemp "${TMPDIR:-/tmp}/ralph-output.XXXXXX")"
    meta_file="$(mktemp "${TMPDIR:-/tmp}/ralph-meta.XXXXXX")"
    run_selected_tool_with_watchdog "$output_file" "$meta_file"
    output="$(cat "$output_file")"
    child_exit_code="$(jq -r '.exitCode // 0' "$meta_file" 2>/dev/null || echo "0")"
    child_timed_out="$(jq -r '.timedOut // false' "$meta_file" 2>/dev/null || echo "false")"
    rm -f "$output_file" "$meta_file"

    pending_after="$(get_pending_story_count)"
    next_story_after="$(get_next_story_field "id")"

    if echo "$output" | grep -q "<promise>COMPLETE</promise>"; then
      echo ""
      echo "Ralph completed all tasks."
      set_current_run_context "" 0 "tool_reported_complete" "$iterations_run"
      finish_run "complete" 0
    fi

    if echo "$output" | grep -q "<promise>REVIEW_REQUIRED</promise>"; then
      echo ""
      echo "Ralph requires human review before continuing."
      set_current_run_context "$next_story_after" "$stagnant_count" "tool_requested_review" "$iterations_run"
      finish_run "review_required" 3
    fi

    if echo "$output" | grep -q "<promise>BLOCKED</promise>"; then
      echo ""
      echo "Ralph is blocked and stopped."
      set_current_run_context "$next_story_after" "$stagnant_count" "tool_reported_blocked" "$iterations_run"
      finish_run "blocked" 2
    fi

    if [ "$pending_after" -eq 0 ]; then
      echo ""
      echo "Ralph completed all tasks."
      set_current_run_context "" 0 "all_stories_passed" "$iterations_run"
      finish_run "complete" 0
    fi

    if [ "$child_timed_out" = "true" ]; then
      echo ""
      echo "Ralph stopped: $TOOL produced no output for $IDLE_TIMEOUT seconds."
      set_current_run_context "$next_story_after" "$stagnant_count" "child_idle_timeout" "$iterations_run"
      finish_run "review_required" 3
    fi

    if [ "${child_exit_code:-0}" != "0" ]; then
      echo ""
      echo "Ralph stopped: $TOOL exited unexpectedly with status $child_exit_code."
      set_current_run_context "$next_story_after" "$stagnant_count" "child_aborted" "$iterations_run"
      finish_run "review_required" 3
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

    set_current_run_context "$next_story_after" "$stagnant_count" "$reason" "$iterations_run"
    persist_current_run_state "running"

    if [ "$stagnant_count" -ge "$STAGNANT_LIMIT" ]; then
      echo ""
      echo "Ralph blocked: story ${next_story_after:-<unknown>} made no progress for $stagnant_count iterations."
      set_current_run_context "$next_story_after" "$stagnant_count" "stagnant_limit_reached" "$iterations_run"
      finish_run "blocked" 2
    fi

    echo "Iteration $i complete. Pending stories: $pending_after. Stagnant count: $stagnant_count."
    sleep 2
  done

  echo ""
  echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
  echo "Check $PROGRESS_FILE for status."
  set_current_run_context "$(get_next_story_field "id")" "$stagnant_count" "max_iterations_reached" "$MAX_ITERATIONS"
  finish_run "max_iterations_reached" 4
}

TOOL="codex"
MAX_ITERATIONS=10
STAGNANT_LIMIT=3
IDLE_TIMEOUT="${RALPH_IDLE_TIMEOUT:-600}"
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
        --idle-timeout)
          IDLE_TIMEOUT="$2"
          shift 2
          ;;
        --idle-timeout=*)
          IDLE_TIMEOUT="${1#*=}"
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
