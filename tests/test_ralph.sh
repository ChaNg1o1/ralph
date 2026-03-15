#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [ "$expected" != "$actual" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"

  if ! grep -Fqx "$expected" "$file_path"; then
    fail "Expected '$expected' in $file_path"
  fi
}

create_workspace() {
  local temp_root project_root ralph_dir

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/ralph-test.XXXXXX")"
  project_root="$temp_root/project"
  ralph_dir="$project_root/scripts/ralph"

  mkdir -p "$ralph_dir/archive"
  git -C "$project_root" init -q

  cp "$REPO_ROOT/ralph.sh" "$ralph_dir/ralph.sh"
  cp "$REPO_ROOT/CODEX.md" "$ralph_dir/CODEX.md"
  cp "$REPO_ROOT/prompt.md" "$ralph_dir/prompt.md"
  cp "$REPO_ROOT/CLAUDE.md" "$ralph_dir/CLAUDE.md"
  chmod +x "$ralph_dir/ralph.sh"

  cat > "$ralph_dir/prd.json" <<'EOF'
{
  "project": "Ralph Test",
  "branchName": "ralph/test-loop",
  "description": "Regression harness",
  "userStories": [
    {
      "id": "US-001",
      "title": "Exercise Ralph loop behavior",
      "priority": 1,
      "passes": false
    }
  ]
}
EOF

  cat > "$ralph_dir/progress.txt" <<'EOF'
# Ralph Progress Log
Started: test
---
EOF

  cat > "$ralph_dir/.ralph-state.json" <<'EOF'
{
  "status": "ready",
  "lastStoryId": "",
  "stagnantCount": 0,
  "lastReason": "initialized",
  "iterationsRun": 0,
  "updatedAt": "2026-03-15T00:00:00Z"
}
EOF

  echo "$project_root"
}

write_stub_codex() {
  local project_root="$1"
  local mode="$2"

  mkdir -p "$project_root/bin"

  cat > "$project_root/bin/codex" <<EOF
#!/bin/bash
cat >/dev/null

case "\${RALPH_TEST_MODE:-$mode}" in
  idle)
    sleep 30
    ;;
  complete)
    echo "<promise>COMPLETE</promise>"
    ;;
  quiet-success)
    exit 0
    ;;
  *)
    echo "Unexpected test mode: \${RALPH_TEST_MODE:-$mode}" >&2
    exit 99
    ;;
esac
EOF

  chmod +x "$project_root/bin/codex"
}

wait_for_state() {
  local state_file="$1"
  local expected_status="$2"
  local max_attempts=50
  local attempt=0

  while [ "$attempt" -lt "$max_attempts" ]; do
    if [ "$(jq -r '.status' "$state_file")" = "$expected_status" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done

  fail "Timed out waiting for status '$expected_status' in $state_file"
}

test_init_writes_runtime_gitignore() {
  local target_root

  target_root="$(mktemp -d "${TMPDIR:-/tmp}/ralph-init.XXXXXX")"
  git -C "$target_root" init -q

  "$REPO_ROOT/ralph.sh" init "$target_root" >/dev/null

  assert_file_contains "$target_root/scripts/ralph/.gitignore" ".last-branch"
  assert_file_contains "$target_root/scripts/ralph/.gitignore" ".ralph-state.json"
}

test_idle_timeout_marks_review_required() {
  local project_root state_file log_file rc

  project_root="$(create_workspace)"
  state_file="$project_root/scripts/ralph/.ralph-state.json"
  log_file="$project_root/idle-timeout.log"
  write_stub_codex "$project_root" "idle"

  set +e
  PATH="$project_root/bin:$PATH" "$project_root/scripts/ralph/ralph.sh" go --tool codex --max-iterations 1 --idle-timeout 1 >"$log_file" 2>&1
  rc=$?
  set -e

  assert_eq "3" "$rc" "Idle timeout should return REVIEW_REQUIRED"
  assert_eq "review_required" "$(jq -r '.status' "$state_file")" "Idle timeout should mark run as review_required"
  assert_eq "child_idle_timeout" "$(jq -r '.lastReason' "$state_file")" "Idle timeout should record child_idle_timeout"
  assert_eq "US-001" "$(jq -r '.lastStoryId' "$state_file")" "Idle timeout should retain the active story id"
}

test_interrupt_marks_run_interrupted() {
  local project_root state_file log_file pid rc

  project_root="$(create_workspace)"
  state_file="$project_root/scripts/ralph/.ralph-state.json"
  log_file="$project_root/interrupt.log"
  write_stub_codex "$project_root" "idle"

  env PATH="$project_root/bin:$PATH" "$project_root/scripts/ralph/ralph.sh" go --tool codex --max-iterations 1 --idle-timeout 20 >"$log_file" 2>&1 &
  pid=$!

  wait_for_state "$state_file" "running"
  kill -TERM "$pid"

  set +e
  wait "$pid"
  rc=$?
  set -e

  assert_eq "143" "$rc" "Interrupt should exit with shell signal status"
  assert_eq "interrupted" "$(jq -r '.status' "$state_file")" "Interrupt should mark run as interrupted"
  assert_eq "signal_term" "$(jq -r '.lastReason' "$state_file")" "Interrupt should record signal_term"
  assert_eq "US-001" "$(jq -r '.lastStoryId' "$state_file")" "Interrupt should retain the active story id"
}

test_init_writes_runtime_gitignore
test_idle_timeout_marks_review_required
test_interrupt_marks_run_interrupted

echo "PASS: Ralph regression checks"
