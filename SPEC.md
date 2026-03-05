# OpenClaw Agent Swarm - Build Specification

## Goal
A production-ready multi-agent coding orchestration system inspired by Elvis Sun's "One-Person Dev Team" setup.
Primary agent: Claude Code. Secondary: Codex. Reviewer: also Claude Code (separate instance).

## Directory Structure
```
openclaw-swarm/
├── scripts/
│   ├── spawn-agent.sh       # Launch agent in tmux + git worktree
│   ├── check-agents.sh      # Poll registry, check PR/CI status
│   └── cleanup-agents.sh    # Remove completed worktrees/branches
├── prompts/
│   └── example-task.txt     # Example task prompt template
├── context/
│   └── business-context.md  # Business/project context file (like Obsidian vault)
├── active-tasks.json         # Task registry
├── active-tasks.json.example # Example for new users
├── swarm.sh                  # Main entry point CLI
├── .env.example              # Env vars template
├── .gitignore
└── README.md
```

## Core Scripts

### spawn-agent.sh
Args: $1=task-id $2=repo-path $3=prompt-file $4=agent(claude|codex) $5=branch-name

What it does:
1. Validate inputs, check disk space (>1GB), check tmux exists
2. Create git worktree: `git worktree add <worktree-path> -b <branch> origin/main`
3. Install deps if package.json exists (npm/pnpm)
4. Build full prompt from: prompt-file + context/business-context.md + customer config snippet
5. Launch tmux session: `tmux new-session -d -s "swarm-<task-id>" -c <worktree-path>`
6. Run agent in tmux:
   - Claude Code: `claude --dangerously-skip-permissions -p "<prompt>"`  
   - Codex: `codex --dangerously-bypass-approvals-and-sandbox "<prompt>"`
7. Register task in active-tasks.json (with file locking via flock):
   ```json
   {
     "id": "task-id",
     "tmuxSession": "swarm-task-id", 
     "agent": "claude",
     "description": "...",
     "repo": "repo-path",
     "worktree": "worktree-path",
     "branch": "branch-name",
     "startedAt": 1234567890000,
     "status": "running",
     "retryCount": 0,
     "notifyOnComplete": true
   }
   ```

### check-agents.sh
Runs every 10 minutes via cron. For each task in registry:
1. Check if tmux session alive
2. If no session and status=running: mark as "tmux-died", attempt respawn (max 3 retries)
3. Check for open PR on branch: `gh pr view --repo <repo> --json number,state,statusCheckRollup`
4. If PR exists:
   - Check CI status (all checks passed?)
   - If CI passed: trigger auto-review (spawn claude code reviewer in separate tmux)
   - If review passed: update status="ready", send Telegram notification
5. Stuck detection: running >60min with no PR -> flag for human
6. Update active-tasks.json atomically (flock)
7. Send Telegram alerts for: ready/stuck/failed tasks

### cleanup-agents.sh  
For tasks with status=done|merged:
1. Kill tmux session if still alive
2. Remove git worktree
3. Remove from active-tasks.json

### swarm.sh (main CLI)
```
Usage:
  ./swarm.sh spawn <task-id> <repo> <prompt-file> [claude|codex] [branch]
  ./swarm.sh check        # Run check-agents.sh once
  ./swarm.sh status       # Show all tasks from registry
  ./swarm.sh cleanup      # Run cleanup-agents.sh
  ./swarm.sh steer <task-id> <message>  # Send message to agent tmux session
  ./swarm.sh kill <task-id>             # Kill agent
  ./swarm.sh logs <task-id>             # Show tmux pane output
```

## Telegram Notification
Read from env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
Function: send_telegram(message) using curl to Telegram Bot API

## Auto-Review (DoD checker)
When PR is detected with CI passing:
1. Spawn `claude --dangerously-skip-permissions -p "Review PR #N in repo X. Check: logic errors, edge cases, security issues. Output: APPROVED or list of CRITICAL issues."` in a separate tmux
2. Parse output; if APPROVED -> mark ready -> notify human
3. If CRITICAL issues -> comment on PR -> respawn fix agent

## .env.example
```
TELEGRAM_BOT_TOKEN=your_token_here
TELEGRAM_CHAT_ID=your_chat_id_here
WORKTREE_BASE_DIR=/tmp/swarm-worktrees
MAX_RETRIES=3
STUCK_THRESHOLD_MINUTES=60
```

## README.md
Full README with: intro, architecture diagram (ASCII), quick start, usage examples, cron setup instructions.

## Requirements
- Pure bash (no Python needed)
- Works with: git, gh, tmux, jq, flock, curl, claude, codex (any of them)
- Graceful degradation: if Telegram not configured, skip; if gh not auth, warn
- Must be clean, well-commented bash

## Completion Signal
When done building all files, run:
openclaw system event --text "Done: openclaw-swarm project built. All scripts ready in ~/dev/openclaw-swarm" --mode now
