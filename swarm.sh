#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# shellcheck source=./scripts/lib.sh
source "$SCRIPTS_DIR/lib.sh"

usage() {
  cat <<USAGE
Usage:
  ./swarm.sh spawn <task-id> <repo> <prompt-file> [claude|codex] [branch]
  ./swarm.sh check
  ./swarm.sh status
  ./swarm.sh cleanup
  ./swarm.sh steer <task-id> <message>
  ./swarm.sh kill <task-id>
  ./swarm.sh logs <task-id>
USAGE
}

ensure_registry_exists

command_name="${1:-}"
if [[ -z "$command_name" ]]; then
  usage
  exit 1
fi
shift || true

case "$command_name" in
  spawn)
    if [[ $# -lt 3 ]]; then
      usage
      exit 1
    fi

    task_id="$1"
    repo_path="$2"
    prompt_file="$3"
    agent="${4:-claude}"
    branch="${5:-swarm/${task_id}-$(date +%Y%m%d%H%M%S)}"

    "$SCRIPTS_DIR/spawn-agent.sh" "$task_id" "$repo_path" "$prompt_file" "$agent" "$branch"
    ;;

  check)
    "$SCRIPTS_DIR/check-agents.sh"
    ;;

  status)
    if [[ "$(jq 'length' "$REGISTRY_FILE")" -eq 0 ]]; then
      printf 'No tasks in registry.\n'
      exit 0
    fi

    table="$(jq -r '
      ["ID","AGENT","STATUS","RETRIES","PR","TMUX","BRANCH"],
      (.[] | [
        .id,
        (.agent // "-"),
        (.status // "-"),
        ((.retryCount // 0) | tostring),
        ((.prNumber // "-") | tostring),
        (.tmuxSession // "-"),
        (.branch // "-")
      ]) | @tsv
    ' "$REGISTRY_FILE")"

    if has_cmd column; then
      printf '%s\n' "$table" | column -t -s $'\t'
    else
      printf '%s\n' "$table"
    fi
    ;;

  cleanup)
    "$SCRIPTS_DIR/cleanup-agents.sh"
    ;;

  steer)
    if [[ $# -lt 2 ]]; then
      usage
      exit 1
    fi

    task_id="$1"
    shift
    message="$*"

    task_json="$(get_task "$task_id")"
    if [[ -z "$task_json" ]]; then
      error "Task not found: $task_id"
      exit 1
    fi

    session_name="$(jq -r '.tmuxSession // empty' <<<"$task_json")"
    if [[ -z "$session_name" ]] || ! tmux has-session -t "$session_name" >/dev/null 2>&1; then
      error "TMUX session not running for task: $task_id"
      exit 1
    fi

    tmux send-keys -t "$session_name" "$message" C-m
    log "Sent steer message to $task_id"
    ;;

  kill)
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi

    task_id="$1"
    task_json="$(get_task "$task_id")"
    if [[ -z "$task_json" ]]; then
      error "Task not found: $task_id"
      exit 1
    fi

    session_name="$(jq -r '.tmuxSession // empty' <<<"$task_json")"
    review_session="$(jq -r '.reviewSession // empty' <<<"$task_json")"

    if [[ -n "$session_name" ]] && tmux has-session -t "$session_name" >/dev/null 2>&1; then
      tmux kill-session -t "$session_name"
    fi

    if [[ -n "$review_session" ]] && tmux has-session -t "$review_session" >/dev/null 2>&1; then
      tmux kill-session -t "$review_session"
    fi

    update_task "$task_id" '{"status":"killed"}'
    send_telegram "[swarm] Task ${task_id} was killed."
    log "Killed task: $task_id"
    ;;

  logs)
    if [[ $# -ne 1 ]]; then
      usage
      exit 1
    fi

    task_id="$1"
    task_json="$(get_task "$task_id")"
    if [[ -z "$task_json" ]]; then
      error "Task not found: $task_id"
      exit 1
    fi

    session_name="$(jq -r '.tmuxSession // empty' <<<"$task_json")"
    if [[ -z "$session_name" ]]; then
      error "Task has no tmux session recorded: $task_id"
      exit 1
    fi

    if tmux has-session -t "$session_name" >/dev/null 2>&1; then
      tmux capture-pane -pt "$session_name" -S -200
    else
      warn "Session not running: $session_name"
      review_output_file="$(jq -r '.reviewOutputFile // empty' <<<"$task_json")"
      if [[ -n "$review_output_file" && -f "$review_output_file" ]]; then
        printf 'Review output (%s):\n' "$review_output_file"
        tail -n 80 "$review_output_file"
      fi
    fi
    ;;

  *)
    usage
    exit 1
    ;;
esac
