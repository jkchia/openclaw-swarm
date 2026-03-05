#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REGISTRY_FILE="${SWARM_REGISTRY_FILE:-$ROOT_DIR/active-tasks.json}"
LOCK_FILE="${SWARM_REGISTRY_LOCK_FILE:-$ROOT_DIR/.active-tasks.lock}"
ENV_FILE="${SWARM_ENV_FILE:-$ROOT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${WORKTREE_BASE_DIR:=/tmp/swarm-worktrees}"
: "${MAX_RETRIES:=3}"
: "${STUCK_THRESHOLD_MINUTES:=60}"

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(date -Is)" "$*" >&2
}

error() {
  printf '[%s] ERROR: %s\n' "$(date -Is)" "$*" >&2
}

now_ms() {
  date +%s%3N 2>/dev/null || echo "$(( $(date +%s) * 1000 ))"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! has_cmd "$cmd"; then
      error "Missing required command: $cmd"
      missing=1
    fi
  done

  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

ensure_registry_exists() {
  mkdir -p "$(dirname "$REGISTRY_FILE")"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    printf '[]\n' >"$REGISTRY_FILE"
  fi

  if ! jq -e 'type == "array"' "$REGISTRY_FILE" >/dev/null 2>&1; then
    error "Registry must be a JSON array: $REGISTRY_FILE"
    exit 1
  fi

  : >"$LOCK_FILE"
}

with_registry_lock() {
  local callback="$1"
  shift

  (
    exec 9>"$LOCK_FILE"
    flock -x 9
    "$callback" "$@"
  )
}

_upsert_task_locked() {
  local task_json="$1"
  local tmp
  tmp="$(mktemp)"

  jq --argjson task "$task_json" '
    if any(.[]; .id == $task.id)
    then map(if .id == $task.id then . + $task else . end)
    else . + [$task]
    end
  ' "$REGISTRY_FILE" >"$tmp"

  mv "$tmp" "$REGISTRY_FILE"
}

upsert_task() {
  with_registry_lock _upsert_task_locked "$1"
}

_update_task_locked() {
  local task_id="$1"
  local patch_json="$2"
  local tmp
  tmp="$(mktemp)"

  jq --arg id "$task_id" --argjson patch "$patch_json" '
    map(if .id == $id then . + $patch else . end)
  ' "$REGISTRY_FILE" >"$tmp"

  mv "$tmp" "$REGISTRY_FILE"
}

update_task() {
  with_registry_lock _update_task_locked "$1" "$2"
}

_remove_task_locked() {
  local task_id="$1"
  local tmp
  tmp="$(mktemp)"

  jq --arg id "$task_id" 'map(select(.id != $id))' "$REGISTRY_FILE" >"$tmp"
  mv "$tmp" "$REGISTRY_FILE"
}

remove_task() {
  with_registry_lock _remove_task_locked "$1"
}

get_task() {
  local task_id="$1"
  jq -c --arg id "$task_id" '.[] | select(.id == $id)' "$REGISTRY_FILE"
}

task_exists() {
  local task_id="$1"
  jq -e --arg id "$task_id" 'any(.[]; .id == $id)' "$REGISTRY_FILE" >/dev/null
}

list_tasks() {
  jq -c '.[]' "$REGISTRY_FILE"
}

send_telegram() {
  local message="$1"

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi

  if ! curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" >/dev/null; then
    warn "Telegram notification failed"
    return 1
  fi

  return 0
}
