#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq flock tmux git
ensure_registry_exists

mapfile -t cleanup_tasks < <(jq -c '.[] | select(.status == "done" or .status == "merged")' "$REGISTRY_FILE")

if [[ ${#cleanup_tasks[@]} -eq 0 ]]; then
  log "No tasks eligible for cleanup"
  exit 0
fi

for task_json in "${cleanup_tasks[@]}"; do
  task_id="$(jq -r '.id // empty' <<<"$task_json")"
  [[ -z "$task_id" ]] && continue

  tmux_session="$(jq -r '.tmuxSession // empty' <<<"$task_json")"
  review_session="$(jq -r '.reviewSession // empty' <<<"$task_json")"
  repo="$(jq -r '.repo // empty' <<<"$task_json")"
  worktree="$(jq -r '.worktree // empty' <<<"$task_json")"

  log "Cleaning task: $task_id"

  if [[ -n "$tmux_session" ]] && tmux has-session -t "$tmux_session" >/dev/null 2>&1; then
    tmux kill-session -t "$tmux_session" || warn "Failed to kill session $tmux_session"
  fi

  if [[ -n "$review_session" ]] && tmux has-session -t "$review_session" >/dev/null 2>&1; then
    tmux kill-session -t "$review_session" || warn "Failed to kill review session $review_session"
  fi

  if [[ -n "$repo" && -n "$worktree" && -d "$worktree" ]]; then
    git -C "$repo" worktree remove "$worktree" --force >/dev/null 2>&1 || {
      warn "git worktree remove failed for $worktree; removing directory directly"
      rm -rf "$worktree"
    }
  fi

  remove_task "$task_id"
  send_telegram "[swarm] Cleaned task ${task_id}."
done

log "Cleanup complete"
