#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq flock tmux git
ensure_registry_exists

GH_AVAILABLE=0
if has_cmd gh && gh auth status >/dev/null 2>&1; then
  GH_AVAILABLE=1
else
  warn "GitHub CLI not available or not authenticated. PR/CI checks are disabled."
fi

start_task_session() {
  local task_id="$1"
  local session_name="$2"
  local worktree_path="$3"
  local agent="$4"

  if [[ ! -d "$worktree_path" ]]; then
    warn "Cannot respawn $task_id: worktree missing at $worktree_path"
    return 1
  fi

  local prompt_bundle="$worktree_path/.swarm-prompt-${task_id}.txt"
  local runner_script="$worktree_path/.swarm-runner-${task_id}.sh"

  if [[ ! -f "$prompt_bundle" ]]; then
    warn "Cannot respawn $task_id: prompt bundle missing ($prompt_bundle)"
    return 1
  fi

  if [[ ! -x "$runner_script" ]]; then
    local agent_exec
    if [[ "$agent" == "claude" ]]; then
      agent_exec='exec claude --dangerously-skip-permissions -p "$prompt"'
    else
      agent_exec='exec codex --dangerously-bypass-approvals-and-sandbox "$prompt"'
    fi

    {
      echo '#!/usr/bin/env bash'
      echo 'set -euo pipefail'
      echo "prompt_file=\"$prompt_bundle\""
      echo 'prompt="$(cat "$prompt_file")"'
      printf '%s\n' "$agent_exec"
    } >"$runner_script"
    chmod +x "$runner_script"
  fi

  tmux new-session -d -s "$session_name" -c "$worktree_path" "$runner_script"
}

get_pr_json() {
  local repo="$1"
  local branch="$2"

  local out
  if out="$(gh pr view --repo "$repo" "$branch" --json number,state,statusCheckRollup,url,headRefName 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi

  if out="$(gh pr list --repo "$repo" --head "$branch" --state all --json number,state,statusCheckRollup,url,headRefName --limit 1 2>/dev/null)"; then
    if [[ "$(jq 'length' <<<"$out")" -gt 0 ]]; then
      jq '.[0]' <<<"$out"
      return 0
    fi
  fi

  return 1
}

actions_latest_ci_status() {
  local repo="$1"
  local branch="$2"

  if [[ $GH_AVAILABLE -ne 1 ]]; then
    printf 'unknown\n'
    return 0
  fi

  # Use Actions runs as a fallback signal when PR statusCheckRollup is empty or delayed.
  # Returns: success | failure | pending | unknown
  local out status conclusion
  if ! out="$(gh run list --repo "$repo" --branch "$branch" --limit 1 --json status,conclusion 2>/dev/null)"; then
    printf 'unknown\n'
    return 0
  fi

  if [[ -z "$out" || "$(jq 'length' <<<"$out" 2>/dev/null || echo 0)" -eq 0 ]]; then
    printf 'unknown\n'
    return 0
  fi

  status="$(jq -r '.[0].status // ""' <<<"$out")"
  conclusion="$(jq -r '.[0].conclusion // ""' <<<"$out")"

  if [[ "$status" != "completed" ]]; then
    printf 'pending\n'
    return 0
  fi

  if [[ "$conclusion" == "success" ]]; then
    printf 'success\n'
  elif [[ -n "$conclusion" ]]; then
    printf 'failure\n'
  else
    printf 'unknown\n'
  fi
}

ci_checks_passed() {
  local pr_json="$1"
  local repo="$2"
  local branch="$3"

  # 1) Prefer GitHub's PR rollup when available.
  local rollup_decision
  rollup_decision="$(jq -r '
    def failed(c): ["FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"] | index(c) != null;
    def pending(s): ["EXPECTED","PENDING","QUEUED","IN_PROGRESS","WAITING","REQUESTED"] | index(s) != null;

    (.statusCheckRollup // []) as $checks
    | if ($checks | length) == 0 then
        "unknown"
      elif any($checks[]?; failed(.conclusion // "")) then
        "false"
      elif any($checks[]?; pending(.status // "")) then
        "false"
      elif any($checks[]?; (.status // "") == "COMPLETED" and (.conclusion == null)) then
        "false"
      else
        "true"
      end
  ' <<<"$pr_json")"

  if [[ "$rollup_decision" == "true" || "$rollup_decision" == "false" ]]; then
    printf '%s\n' "$rollup_decision"
    return 0
  fi

  # 2) Fallback: use latest Actions run for the branch (handles empty/delayed rollups).
  case "$(actions_latest_ci_status "$repo" "$branch")" in
    success) printf 'true\n' ;;
    pending) printf 'false\n' ;;
    failure) printf 'false\n' ;;
    *) printf 'false\n' ;;
  esac
}

spawn_auto_review() {
  local task_json="$1"
  local pr_number="$2"

  if ! has_cmd claude; then
    warn "Cannot run auto-review: claude command not available"
    return 1
  fi

  local task_id repo worktree session_name review_prompt review_prompt_file review_output_file review_runner
  task_id="$(jq -r '.id' <<<"$task_json")"
  repo="$(jq -r '.repo' <<<"$task_json")"
  worktree="$(jq -r '.worktree' <<<"$task_json")"
  session_name="swarm-review-${task_id}"

  review_prompt="Review PR #${pr_number} in repo ${repo}. Check: logic errors, edge cases, security issues. Output: APPROVED or list of CRITICAL issues."
  review_prompt_file="$worktree/.swarm-review-${pr_number}.prompt.txt"
  review_output_file="$worktree/.swarm-review-${pr_number}.out.txt"
  review_runner="$worktree/.swarm-review-${pr_number}.sh"

  printf '%s\n' "$review_prompt" >"$review_prompt_file"

  cat >"$review_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
prompt="\$(cat \"$review_prompt_file\")"
claude --dangerously-skip-permissions -p "\$prompt" 2>&1 | tee "${review_output_file}"
RUNNER

  chmod +x "$review_runner"

  tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
  tmux new-session -d -s "$session_name" -c "$worktree" "$review_runner"

  update_task "$task_id" "$(jq -n \
    --arg status "reviewing" \
    --arg reviewStatus "running" \
    --arg reviewSession "$session_name" \
    --arg reviewOutputFile "$review_output_file" \
    --argjson prNumber "$pr_number" \
    '{
      status: $status,
      reviewStatus: $reviewStatus,
      reviewSession: $reviewSession,
      reviewOutputFile: $reviewOutputFile,
      prNumber: $prNumber
    }')"

  send_telegram "[swarm] Auto-review started for task ${task_id} (PR #${pr_number})."
  log "Auto-review started for task=$task_id pr=$pr_number"
}

evaluate_review_result() {
  local output_file="$1"

  if [[ ! -f "$output_file" ]]; then
    printf 'missing\n'
    return 0
  fi

  if grep -Eiq 'CRITICAL' "$output_file"; then
    printf 'critical\n'
  elif grep -Eiq '\\bAPPROVED\\b' "$output_file"; then
    printf 'approved\n'
  else
    printf 'unknown\n'
  fi
}

post_critical_comment() {
  local repo="$1"
  local pr_number="$2"
  local output_file="$3"

  if [[ $GH_AVAILABLE -ne 1 ]]; then
    return 0
  fi

  local excerpt
  excerpt="$(sed -n '1,80p' "$output_file" 2>/dev/null || true)"
  if [[ -z "$excerpt" ]]; then
    excerpt="Auto-review reported CRITICAL issues but no output was captured."
  fi

  gh pr comment "$pr_number" --repo "$repo" --body "Auto-review found CRITICAL issues:\n\n${excerpt}" >/dev/null 2>&1 || \
    warn "Failed to post PR comment for PR #$pr_number"
}

mapfile -t tasks < <(list_tasks)

if [[ ${#tasks[@]} -eq 0 ]]; then
  log "No active tasks to check"
  exit 0
fi

current_ms="$(now_ms)"
threshold_ms=$((STUCK_THRESHOLD_MINUTES * 60 * 1000))

for task_json in "${tasks[@]}"; do
  task_id="$(jq -r '.id // empty' <<<"$task_json")"
  [[ -z "$task_id" ]] && continue

  status="$(jq -r '.status // "running"' <<<"$task_json")"
  tmux_session="$(jq -r '.tmuxSession // empty' <<<"$task_json")"
  retry_count="$(jq -r '.retryCount // 0' <<<"$task_json")"
  agent="$(jq -r '.agent // "claude"' <<<"$task_json")"
  worktree="$(jq -r '.worktree // empty' <<<"$task_json")"
  branch="$(jq -r '.branch // empty' <<<"$task_json")"
  repo="$(jq -r '.repo // empty' <<<"$task_json")"
  started_at="$(jq -r '.startedAt // 0' <<<"$task_json")"
  review_status="$(jq -r '.reviewStatus // "none"' <<<"$task_json")"
  review_session="$(jq -r '.reviewSession // empty' <<<"$task_json")"
  review_output_file="$(jq -r '.reviewOutputFile // empty' <<<"$task_json")"
  notify_on_complete="$(jq -r '.notifyOnComplete // true' <<<"$task_json")"

  log "Checking task: $task_id (status=$status)"

  if [[ "$status" == "done" || "$status" == "merged" ]]; then
    continue
  fi

  session_alive=0
  if [[ -n "$tmux_session" ]] && tmux has-session -t "$tmux_session" >/dev/null 2>&1; then
    session_alive=1
  fi

  if [[ "$status" == "running" && $session_alive -eq 0 ]]; then
    update_task "$task_id" '{"status":"tmux-died"}'
    if [[ "$retry_count" =~ ^[0-9]+$ ]] && (( retry_count < MAX_RETRIES )); then
      if start_task_session "$task_id" "$tmux_session" "$worktree" "$agent"; then
        retry_count=$((retry_count + 1))
        update_task "$task_id" "$(jq -n \
          --arg status "running" \
          --argjson retries "$retry_count" \
          --argjson heartbeat "$(now_ms)" \
          '{status: $status, retryCount: $retries, lastRespawnAt: $heartbeat}')"
        send_telegram "[swarm] Task ${task_id} respawned (${retry_count}/${MAX_RETRIES})."
      else
        update_task "$task_id" '{"status":"failed"}'
        send_telegram "[swarm] Task ${task_id} failed to respawn."
      fi
    else
      update_task "$task_id" '{"status":"failed"}'
      send_telegram "[swarm] Task ${task_id} exceeded retry limit and is marked failed."
    fi
    status="$(jq -r '.status' <<<"$(get_task "$task_id")")"
  fi

  has_pr=0
  pr_json=''

  if [[ $GH_AVAILABLE -eq 1 && -n "$repo" && -n "$branch" ]]; then
    if pr_json="$(get_pr_json "$repo" "$branch")"; then
      has_pr=1
      pr_number="$(jq -r '.number' <<<"$pr_json")"
      pr_state="$(jq -r '.state // "UNKNOWN"' <<<"$pr_json")"
      update_task "$task_id" "$(jq -n --argjson pr "$pr_number" --arg state "$pr_state" '{prNumber:$pr, prState:$state}')"

      ci_passed="$(ci_checks_passed "$pr_json" "$repo" "$branch")"
      if [[ "$ci_passed" == "true" ]]; then
        if [[ "$review_status" == "none" || "$review_status" == "failed" ]]; then
          spawn_auto_review "$task_json" "$pr_number" || true
        elif [[ "$review_status" == "running" ]]; then
          review_alive=0
          if [[ -n "$review_session" ]] && tmux has-session -t "$review_session" >/dev/null 2>&1; then
            review_alive=1
          fi

          if [[ $review_alive -eq 0 ]]; then
            review_result="$(evaluate_review_result "$review_output_file")"
            case "$review_result" in
              approved)
                update_task "$task_id" "$(jq -n \
                  --arg status "ready" \
                  --arg reviewStatus "approved" \
                  --argjson readyAt "$(now_ms)" \
                  '{status:$status, reviewStatus:$reviewStatus, readyAt:$readyAt}')"
                if [[ "$notify_on_complete" == "true" ]]; then
                  send_telegram "[swarm] Task ${task_id} is READY (PR #${pr_number})."
                fi
                ;;
              critical)
                update_task "$task_id" '{"status":"running","reviewStatus":"critical"}'
                post_critical_comment "$repo" "$pr_number" "$review_output_file"

                if [[ $session_alive -eq 1 ]]; then
                  tmux send-keys -t "$tmux_session" "Auto-review found CRITICAL issues in PR #${pr_number}. Please inspect and fix immediately." C-m
                else
                  start_task_session "$task_id" "$tmux_session" "$worktree" "$agent" || true
                fi

                send_telegram "[swarm] Task ${task_id} has CRITICAL review findings; fix cycle re-triggered."
                ;;
              missing)
                update_task "$task_id" '{"status":"review-failed","reviewStatus":"failed"}'
                send_telegram "[swarm] Task ${task_id} review output missing; marked review-failed."
                ;;
              *)
                update_task "$task_id" '{"status":"review-failed","reviewStatus":"failed"}'
                send_telegram "[swarm] Task ${task_id} review ended without APPROVED/CRITICAL signal."
                ;;
            esac
          fi
        elif [[ "$review_status" == "approved" ]]; then
          update_task "$task_id" '{"status":"ready"}'
        fi
      fi
    fi
  fi

  if [[ "$status" == "running" && $has_pr -eq 0 ]]; then
    if [[ ! "$started_at" =~ ^[0-9]+$ ]]; then
      started_at=0
    fi

    elapsed_ms=$((current_ms - started_at))
    stuck_notified="$(jq -r '.stuckNotified // false' <<<"$task_json")"
    if (( elapsed_ms > threshold_ms )) && [[ "$stuck_notified" != "true" ]]; then
      update_task "$task_id" '{"status":"stuck","stuckNotified":true}'
      send_telegram "[swarm] Task ${task_id} appears stuck (>${STUCK_THRESHOLD_MINUTES} minutes without PR)."
      warn "Task flagged as stuck: $task_id"
    fi
  fi

done

log "Agent check completed"
