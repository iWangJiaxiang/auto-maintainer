#!/usr/bin/env bash
# =============================================================================
#  auto-maintainer — configuration file
# =============================================================================
#  Copy to one of the following locations (checked in order):
#    <git-root>/auto-maintainer.config.sh    ← project-specific config
#    ~/.config/auto-maintainer/config.sh     ← global default
#
#  Or pass explicitly: auto-maintainer -c /path/to/config.sh
#
#  NOTE: REPO is NOT required — it is auto-detected from git remote origin.
#        Only set it if you need to override (e.g. fork workflows).
# =============================================================================

# ─── AI Tool ──────────────────────────────────────────────────────────────────
# Which AI coding tool to invoke for generating fixes.
#
#   claude / claude-code  →  claude --dangerously-skip-permissions -p <prompt>
#   codex  / openai       →  codex --approval-mode full-auto <prompt>
#   script:/abs/path.sh   →  Custom script (ISSUE_NUMBER/TITLE/BODY/URL env vars)
#
AI_TOOL="claude"

# ─── Label filters ────────────────────────────────────────────────────────────
# Issues must match AT LEAST ONE of these labels (OR logic).
# Set to an empty array () to process all open issues regardless of labels.
INCLUDE_LABELS=("bug" "good first issue")

# Issues with ANY of these labels are skipped entirely.
EXCLUDE_LABELS=("wontfix" "duplicate" "needs-discussion" "blocked" "in-progress")

# Priority order (highest → lowest).
# Issues matching an earlier label are processed first.
# Issues without any priority label receive score 0 and are processed last.
PRIORITY_LABELS=(
  "priority:critical"
  "priority:high"
  "priority:medium"
  "priority:low"
)

# ─── Quota ────────────────────────────────────────────────────────────────────
# Stop processing when remaining quota falls below this percentage.
QUOTA_THRESHOLD=30

# Skip issue processing completely if 7-day API utilization percentage exceeds this
CLAUDE_MAX_WEEKLY_USAGE=""

# Used when the API key cannot be found automatically (e.g. claude.ai Pro
# session without an API key). Estimate your current remaining % or pass
# --quota 65 at runtime to override.
MANUAL_QUOTA_PERCENT=100

# Hours until next quota reset (determines how long to sleep when quota is low).
MANUAL_QUOTA_RESET_HOURS=5

# ─── Git & PR ─────────────────────────────────────────────────────────────────
PR_BASE_BRANCH="main"
AUTO_MERGE_METHOD="squash"   # squash | merge | rebase

# ─── CI ───────────────────────────────────────────────────────────────────────
CI_TIMEOUT=1800      # Max seconds to wait for CI checks (default: 30 min)
CI_POLL_INTERVAL=30  # Seconds between CI status polls

# ─── Run limits ───────────────────────────────────────────────────────────────
MAX_ISSUES_PER_RUN=0   # 0 = unlimited; set to N to cap issues per invocation

# ─── Optional: explicit repo override ────────────────────────────────────────
# Normally auto-detected from `git remote get-url origin`.
# Uncomment and set only if you need to override (e.g. contributing to a fork).
# REPO="upstream-org/upstream-repo"

# ─── Optional: explicit API keys ─────────────────────────────────────────────
# The script discovers keys automatically from standard locations:
#   Anthropic: ANTHROPIC_API_KEY env → ~/.claude/settings.json → ~/.anthropic/credentials
#   OpenAI:    OPENAI_API_KEY env    → ~/.codex/config.json    → ~/.config/openai/credentials
#
# Only set these if auto-discovery fails:
# export ANTHROPIC_API_KEY="sk-ant-..."
# export OPENAI_API_KEY="sk-..."
