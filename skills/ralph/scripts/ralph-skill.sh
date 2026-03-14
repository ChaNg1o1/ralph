#!/bin/bash

set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$SKILL_DIR/assets/template"
COMMAND="${1:-status}"

usage() {
  cat <<'EOF'
Usage:
  ralph-skill.sh init [target_project_dir] [--force]
  ralph-skill.sh go [args...]
  ralph-skill.sh resume [args...]
  ralph-skill.sh status
EOF
}

find_project_entry() {
  if [ -f "$PWD/ralph" ]; then
    echo "$PWD/ralph"
    return 0
  fi

  if [ -f "$PWD/scripts/ralph/ralph.sh" ]; then
    echo "$PWD/scripts/ralph/ralph.sh"
    return 0
  fi

  return 1
}

case "$COMMAND" in
  init)
    shift || true
    exec "$TEMPLATE_DIR/ralph.sh" init "$@"
    ;;
  go|resume|status)
    entry="$(find_project_entry || true)"
    if [ -z "$entry" ]; then
      echo "Error: Ralph is not initialized in the current project."
      echo "Run \$ralph init first."
      exit 1
    fi
    shift || true
    exec "$entry" "$COMMAND" "$@"
    ;;
  --help|-h|help)
    usage
    exit 0
    ;;
  *)
    echo "Error: Unknown command '$COMMAND'"
    usage
    exit 1
    ;;
esac
