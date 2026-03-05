#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Usage: $0 <task-id> <repo-path> <prompt-file> <agent:claude|codex> <branch-name>
USAGE
}

if [[ $# -ne 5 ]]; then
  usage
  exit 1
fi

task_id="$1"
repo_path="$2"
prompt_file="$3"
agent="$4"
branch_name="$5"

case "$agent" in
  claude | codex) ;;
  *)
    error "Agent must be one of: claude, codex"
    exit 1
    ;;
esac

require_cmd git tmux jq flock df awk sed
if [[ "$agent" == "claude" ]]; then
  require_cmd claude
else
  require_cmd codex
fi

ensure_registry_exists

if [[ ! -d "$repo_path" ]]; then
  error "Repository path does not exist: $repo_path"
  exit 1
fi
repo_path="$(cd "$repo_path" && pwd)"

if [[ ! -d "$repo_path/.git" ]]; then
  error "Not a git repository: $repo_path"
  exit 1
fi

if [[ ! -f "$prompt_file" ]]; then
  error "Prompt file not found: $prompt_file"
  exit 1
fi
prompt_file="$(cd "$(dirname "$prompt_file")" && pwd)/$(basename "$prompt_file")"

if task_exists "$task_id"; then
  error "Task already exists in registry: $task_id"
  exit 1
fi

session_name="swarm-${task_id}"
if tmux has-session -t "$session_name" 2>/dev/null; then
  error "TMUX session already exists: $session_name"
  exit 1
fi

mkdir -p "$WORKTREE_BASE_DIR"

available_kb="$(df -Pk "$WORKTREE_BASE_DIR" | awk 'NR==2 {print $4}')"
if [[ -z "$available_kb" || "$available_kb" -lt 1048576 ]]; then
  error "Insufficient disk space in $WORKTREE_BASE_DIR (need at least 1GB free)"
  exit 1
fi

worktree_path="${WORKTREE_BASE_DIR%/}/${task_id}"
if [[ -e "$worktree_path" ]]; then
  error "Worktree path already exists: $worktree_path"
  exit 1
fi

created_worktree=0

cleanup_on_error() {
  if [[ $created_worktree -eq 1 ]]; then
    warn "Spawn failed, cleaning up worktree/session for $task_id"
    tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
    git -C "$repo_path" worktree remove "$worktree_path" --force >/dev/null 2>&1 || rm -rf "$worktree_path"
  fi
}

trap cleanup_on_error ERR

log "Creating worktree: $worktree_path"
git -C "$repo_path" fetch origin main >/dev/null 2>&1 || true
git -C "$repo_path" worktree add "$worktree_path" -b "$branch_name" origin/main
created_worktree=1

if [[ -f "$worktree_path/package.json" ]]; then
  if [[ -f "$worktree_path/pnpm-lock.yaml" && -x "$(command -v pnpm 2>/dev/null || true)" ]]; then
    log "Installing dependencies via pnpm"
    (
      cd "$worktree_path"
      pnpm install --frozen-lockfile || pnpm install
    )
  elif [[ -x "$(command -v npm 2>/dev/null || true)" ]]; then
    log "Installing dependencies via npm"
    (
      cd "$worktree_path"
      npm ci || npm install
    )
  else
    warn "package.json found but neither pnpm nor npm is available"
  fi
fi

context_file="$ROOT_DIR/context/business-context.md"
customer_config_file="$ROOT_DIR/customer-config-snippet.md"

full_prompt="$(cat "$prompt_file")"

if [[ -f "$context_file" ]]; then
  full_prompt+=$'\n\n# Business Context\n'
  full_prompt+="$(cat "$context_file")"
fi

if [[ -n "${CUSTOMER_CONFIG_SNIPPET:-}" ]]; then
  full_prompt+=$'\n\n# Customer Config Snippet\n'
  full_prompt+="$CUSTOMER_CONFIG_SNIPPET"
elif [[ -f "$customer_config_file" ]]; then
  full_prompt+=$'\n\n# Customer Config Snippet\n'
  full_prompt+="$(cat "$customer_config_file")"
fi

prompt_bundle="$worktree_path/.swarm-prompt-${task_id}.txt"
printf '%s\n' "$full_prompt" >"$prompt_bundle"

runner_script="$worktree_path/.swarm-runner-${task_id}.sh"
if [[ "$agent" == "claude" ]]; then
  agent_exec='exec claude --dangerously-skip-permissions -p "$prompt"'
else
  agent_exec='exec codex --dangerously-bypass-approvals-and-sandbox "$prompt"'
fi

cat >"$runner_script" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
prompt_file="$prompt_bundle"
prompt="$(cat \"$prompt_bundle\")"
$agent_exec
RUNNER

chmod +x "$runner_script"

tmux new-session -d -s "$session_name" -c "$worktree_path" "$runner_script"

description="$(awk 'NF {print; exit}' "$prompt_file")"
if [[ -z "$description" ]]; then
  description="Task $task_id"
fi

started_at="$(now_ms)"
task_json="$(jq -n \
  --arg id "$task_id" \
  --arg tmuxSession "$session_name" \
  --arg taskAgent "$agent" \
  --arg taskDescription "$description" \
  --arg taskRepo "$repo_path" \
  --arg taskWorktree "$worktree_path" \
  --arg taskBranch "$branch_name" \
  --argjson startedAt "$started_at" \
  '{
    id: $id,
    tmuxSession: $tmuxSession,
    agent: $taskAgent,
    description: $taskDescription,
    repo: $taskRepo,
    worktree: $taskWorktree,
    branch: $taskBranch,
    startedAt: $startedAt,
    status: "running",
    retryCount: 0,
    notifyOnComplete: true,
    reviewStatus: "none"
  }')"

upsert_task "$task_json"

created_worktree=0
trap - ERR

send_telegram "[swarm] Task ${task_id} started with ${agent} on branch ${branch_name}."
log "Task spawned: id=$task_id agent=$agent session=$session_name"
