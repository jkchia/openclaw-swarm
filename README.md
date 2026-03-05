# OpenClaw Swarm

Production-oriented multi-agent coding orchestration in pure Bash. It manages agent execution in isolated git worktrees, monitors progress, checks PR/CI state, triggers automated review, and notifies humans when tasks are ready or blocked.

## Architecture

```text
                   +-------------------+
                   |      swarm.sh     |
                   |  (CLI entrypoint) |
                   +---------+---------+
                             |
        +--------------------+--------------------+
        |                    |                    |
+-------v--------+   +-------v--------+   +-------v--------+
| spawn-agent.sh |   | check-agents.sh|   |cleanup-agents.sh|
+-------+--------+   +-------+--------+   +-------+--------+
        |                    |                    |
        |                    |                    |
+-------v-----------------------------------------v--------+
|                 active-tasks.json (registry)             |
|        guarded by flock for atomic read/write updates    |
+-------+-----------------------------------------+--------+
        |                                         |
+-------v--------+                       +--------v--------+
| tmux sessions  |                       | git worktrees   |
| agent + review |                       | per task branch |
+----------------+                       +-----------------+
```

## Repository Layout

```text
openclaw-swarm/
├── scripts/
│   ├── lib.sh
│   ├── spawn-agent.sh
│   ├── check-agents.sh
│   └── cleanup-agents.sh
├── prompts/
│   └── example-task.txt
├── context/
│   └── business-context.md
├── active-tasks.json
├── active-tasks.json.example
├── swarm.sh
├── .env.example
├── .gitignore
└── README.md
```

## Prerequisites

Install tools available in your environment:
- `bash`, `git`, `jq`, `flock`, `tmux`, `curl`
- `gh` (optional but recommended for PR/CI checks)
- `claude` and/or `codex` CLI
- `npm` or `pnpm` if target repos require Node dependencies

## Quick Start

1. Copy env template:
```bash
cp .env.example .env
```

2. Edit `.env` with Telegram settings (optional).

3. Spawn an agent task:
```bash
./swarm.sh spawn task-login-fix /path/to/repo prompts/example-task.txt claude swarm/task-login-fix
```

4. Check task registry status:
```bash
./swarm.sh status
```

5. Run monitor pass manually:
```bash
./swarm.sh check
```

## Usage

Spawn (with defaults for optional args):
```bash
./swarm.sh spawn <task-id> <repo> <prompt-file> [claude|codex] [branch]
```

Status:
```bash
./swarm.sh status
```

Steer a running task:
```bash
./swarm.sh steer <task-id> "Focus on failing tests first"
```

Task logs:
```bash
./swarm.sh logs <task-id>
```

Kill task:
```bash
./swarm.sh kill <task-id>
```

Cleanup finished tasks (`done`/`merged`):
```bash
./swarm.sh cleanup
```

## Monitoring Behavior (`check-agents.sh`)

For each task in `active-tasks.json`:
- Confirms tmux session is alive.
- Marks `tmux-died` and attempts respawn (up to `MAX_RETRIES`).
- Queries PR status for task branch when `gh` is available.
- If CI passes, starts an auto-review tmux session with Claude.
- Parses review result:
  - `APPROVED` -> marks task `ready` and notifies.
  - `CRITICAL` -> comments on PR and re-triggers fix loop.
- Flags tasks as `stuck` when running too long without a PR.

If Telegram env vars are missing, notifications are skipped gracefully.
If `gh` auth is unavailable, PR/CI checks are skipped with warnings.

## Cron Setup

Run checks every 10 minutes:
```cron
*/10 * * * * cd /home/ufei/dev/openclaw-swarm && ./swarm.sh check >> /tmp/openclaw-swarm-check.log 2>&1
```

Optional cleanup once per day:
```cron
15 3 * * * cd /home/ufei/dev/openclaw-swarm && ./swarm.sh cleanup >> /tmp/openclaw-swarm-cleanup.log 2>&1
```

## Notes

- Registry writes are atomic and lock-protected via `flock`.
- Worktrees default to `/tmp/swarm-worktrees` and can be changed via `.env`.
- `context/business-context.md` is appended to every spawned prompt.
- Optional `customer-config-snippet.md` or `CUSTOMER_CONFIG_SNIPPET` can further augment prompts.
