#!/usr/bin/env bash
# =============================================================================
#  auto-maintainer — AI-powered GitHub Issue Auto-resolver
# =============================================================================
#  Run from the root of a git repository:
#    auto-maintainer [options]
#
#  Picks open issues via gh CLI, sends them to an AI coding tool, commits the
#  fix, opens a PR, waits for CI, and auto-merges — with quota management.
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

readonly VERSION="1.1.0"
readonly BIN_NAME="auto-maintainer"
# Where local per-run lock and state files are written
readonly RUN_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
readonly STATE_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/${BIN_NAME}"

# ─── Colors (auto-disabled when stdout is not a TTY) ─────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m';  BOLD=$'\033[1m'
  DIM=$'\033[2m';    NC=$'\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ─── Default configuration (override in config.sh) ───────────────────────────
AI_TOOL="claude"               # claude|claude-code|codex|openai|script:/path
INCLUDE_LABELS=()              # Must match ≥1 label (OR logic); empty = all
EXCLUDE_LABELS=()              # Skip issues that have any of these labels
PRIORITY_LABELS=()             # Ordered high→low; earlier label = higher score
QUOTA_THRESHOLD=30             # Pause when remaining quota % falls below this
PR_BASE_BRANCH="main"
AUTO_MERGE_METHOD="squash"     # squash | merge | rebase
CI_TIMEOUT=1800                # Max seconds to wait for CI (default: 30 min)
CI_POLL_INTERVAL=30            # Seconds between CI polls
MAX_ISSUES_PER_RUN=0           # 0 = unlimited
MANUAL_QUOTA_PERCENT=100       # Assumed remaining % when no API key is found
MANUAL_QUOTA_RESET_HOURS=5     # Hours until next reset (manual fallback)

# ─── Runtime state ────────────────────────────────────────────────────────────
REPO=""                        # Populated by detect_repo()
REPO_DIR=""                    # Populated by init_repo_dir()
VERBOSE=false
DRY_RUN=false
LOOP_MODE=false
CONFIG_FILE=""
LOCK_FILE=""
QUOTA_RESET_TIME=""
PROCESSED_ISSUES=" "           # Space-padded issue numbers processed this run

# Run statistics
_STAT_OK=0
_STAT_FAIL=0
_STAT_SKIP=0

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  case "$level" in
    INFO)  printf "${DIM}%s${NC}  ${BLUE}INFO${NC}   %s\n"   "$ts" "$msg" ;;
    WARN)  printf "${DIM}%s${NC}  ${YELLOW}WARN${NC}   %s\n" "$ts" "$msg" ;;
    ERROR) printf "${DIM}%s${NC}  ${RED}ERROR${NC}  %s\n"    "$ts" "$msg" >&2 ;;
    OK)    printf "${DIM}%s${NC}  ${GREEN} OK ${NC}   %s\n"  "$ts" "$msg" ;;
    STEP)  printf "\n${BOLD}${CYAN}  ┄┄ %s${NC}\n"           "$msg" ;;
    DEBUG) [[ "$VERBOSE" == "true" ]] && \
           printf "${DIM}%s  DBG    %s${NC}\n"               "$ts" "$msg" ;;
  esac
}

die() { log ERROR "$*"; exit 1; }

# Retry a command up to N times with a delay between attempts
retry() {
  local attempts="$1" delay="$2"; shift 2
  local n=0
  until "$@"; do
    n=$(( n + 1 ))
    [[ $n -ge $attempts ]] && return 1
    log WARN "Attempt ${n}/${attempts} failed — retrying in ${delay}s…"
    sleep "$delay"
  done
}

# ─── Cleanup & signal handling ────────────────────────────────────────────────
_cleanup() {
  # Always return to the base branch and remove the lock file on exit
  [[ -n "${REPO_DIR:-}" ]] && git -C "$REPO_DIR" checkout "${PR_BASE_BRANCH}" \
    --quiet 2>/dev/null || true
  [[ -n "${LOCK_FILE:-}" ]] && rm -f "$LOCK_FILE"
}

trap '_cleanup' EXIT
trap 'log WARN "Interrupted — cleaning up."; exit 130' INT TERM HUP

# ─── Lock file (prevents concurrent runs on the same repo) ───────────────────
acquire_lock() {
  mkdir -p "$RUN_DIR"
  local slug; slug=$(printf '%s' "$REPO_DIR" | tr '/' '-' | tr -cs 'a-zA-Z0-9-' '-')
  LOCK_FILE="${RUN_DIR}/${BIN_NAME}-${slug}.lock"

  if [[ -f "$LOCK_FILE" ]]; then
    local old_pid; old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      die "Already running (PID ${old_pid}). Remove ${LOCK_FILE} to force-reset."
    fi
    log WARN "Removing stale lock file from a previous crashed run."
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  log DEBUG "Lock acquired: $LOCK_FILE"
}

# ─── Config loading ───────────────────────────────────────────────────────────
load_config() {
  [[ -f "$1" ]] || die "Config file not found: $1"
  # shellcheck source=/dev/null
  source "$1"
  log DEBUG "Config loaded: $1"
}

# ─── Repository detection ────────────────────────────────────────────────────
#  Call from the git working tree; REPO_DIR and REPO are set automatically.

init_repo_dir() {
  # Resolve git root from the current working directory
  REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "Not inside a git repository. Run ${BIN_NAME} from your project root."
  log DEBUG "Git root: $REPO_DIR"
}

detect_repo() {
  # If REPO was explicitly set in config, trust it
  if [[ -n "${REPO:-}" ]]; then
    log DEBUG "REPO set explicitly: $REPO"
    return 0
  fi

  local url
  url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null) \
    || die "No 'origin' remote found. Configure one or set REPO in config."

  # Handles:  https://github.com/owner/repo[.git]
  #           git@github.com:owner/repo[.git]
  #           gh://github.com/owner/repo
  if [[ "$url" =~ github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/?$ ]]; then
    REPO="${BASH_REMATCH[1]%.git}"
    log DEBUG "Detected repo: $REPO  (from remote: $url)"
  else
    die "Cannot parse GitHub repo from remote URL: ${url}
Supported formats: https://github.com/owner/repo  or  git@github.com:owner/repo
Alternatively, set REPO=\"owner/repo\" in your config file."
  fi
}

# ─── Local API key discovery ─────────────────────────────────────────────────
#  Tries multiple standard locations before falling back to an empty string.
#  Priority: environment variable > tool config files > global config files

_read_json_field() {
  # Usage: _read_json_field <file> <jq-expression>
  local file="$1" expr="$2"
  [[ -f "$file" ]] || return 1
  local val
  val=$(jq -r "${expr} // empty" "$file" 2>/dev/null) || return 1
  [[ -n "$val" ]] && echo "$val" && return 0
  return 1
}

_read_ini_field() {
  # Usage: _read_ini_field <file> <key-pattern>
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^\s*${key}\s*=" "$file" 2>/dev/null \
    | head -1 | sed "s/.*=\s*//" | tr -d "\"'" || return 1
}

get_anthropic_api_key() {
  # 1. Explicit environment variable (highest priority)
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo "$ANTHROPIC_API_KEY" && return 0

  # 2. Claude Code stores settings in ~/.claude/
  #    Key may be in the env block or as a top-level field
  local claude_settings="${HOME}/.claude/settings.json"
  _read_json_field "$claude_settings" '.env.ANTHROPIC_API_KEY' && return 0
  _read_json_field "$claude_settings" '.apiKey'                 && return 0
  _read_json_field "$claude_settings" '.api_key'                && return 0

  # 3. ~/.claude/.credentials.json (some Claude Code versions)
  _read_json_field "${HOME}/.claude/.credentials.json" '.apiKey'  && return 0
  _read_json_field "${HOME}/.claude/.credentials.json" '.api_key' && return 0

  # 4. Anthropic credentials file (ini-style: api_key = sk-ant-...)
  for f in \
    "${HOME}/.anthropic/credentials" \
    "${HOME}/.config/anthropic/credentials" \
    "${XDG_CONFIG_HOME:-${HOME}/.config}/anthropic/credentials"
  do
    local val; val=$(_read_ini_field "$f" 'api_key') && [[ -n "$val" ]] \
      && echo "$val" && return 0
    val=$(_read_ini_field "$f" 'ANTHROPIC_API_KEY') && [[ -n "$val" ]] \
      && echo "$val" && return 0
  done

  echo ""; return 1
}

get_openai_api_key() {
  # 1. Explicit environment variable
  [[ -n "${OPENAI_API_KEY:-}" ]] && echo "$OPENAI_API_KEY" && return 0

  # 2. Codex CLI config (~/.codex/config.json)
  _read_json_field "${HOME}/.codex/config.json"       '.apiKey'  && return 0
  _read_json_field "${HOME}/.codex/config.json"       '.api_key' && return 0

  # 3. OpenAI credentials file
  for f in \
    "${HOME}/.openai/credentials" \
    "${HOME}/.config/openai/credentials" \
    "${XDG_CONFIG_HOME:-${HOME}/.config}/openai/credentials"
  do
    local val; val=$(_read_ini_field "$f" 'api_key') && [[ -n "$val" ]] \
      && echo "$val" && return 0
    val=$(_read_ini_field "$f" 'OPENAI_API_KEY') && [[ -n "$val" ]] \
      && echo "$val" && return 0
  done

  # 4. OpenAI config.json
  _read_json_field "${HOME}/.config/openai/config.json" '.api_key' && return 0

  echo ""; return 1
}

# ─── Quota: Anthropic API ────────────────────────────────────────────────────
_claude_cache_ts=0
_claude_cache_pct=100

check_claude_quota() {
  local now; now=$(date +%s)
  (( now - _claude_cache_ts < 300 )) && { echo "$_claude_cache_pct"; return; }

  local api_key; api_key=$(get_anthropic_api_key)
  if [[ -z "$api_key" ]]; then
    log DEBUG "No Anthropic API key found anywhere — using MANUAL_QUOTA_PERCENT"
    echo "$MANUAL_QUOTA_PERCENT"; return
  fi
  log DEBUG "Claude quota check using key: ${api_key:0:12}…"

  local hfile; hfile=$(mktemp)
  # A minimal 1-token request just to read the rate-limit headers
  curl -sf -D "$hfile" \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $api_key" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    -o /dev/null 2>/dev/null || true

  local limit remaining
  limit=$(     grep -i '^anthropic-ratelimit-tokens-limit:'     "$hfile" \
               | awk '{print $2}' | tr -d '\r' | head -1)
  remaining=$( grep -i '^anthropic-ratelimit-tokens-remaining:' "$hfile" \
               | awk '{print $2}' | tr -d '\r' | head -1)
  QUOTA_RESET_TIME=$(grep -i '^anthropic-ratelimit-tokens-reset:' "$hfile" \
               | awk '{print $2}' | tr -d '\r' | head -1)
  rm -f "$hfile"

  local pct=100
  if [[ -n "${limit:-}" && "${limit:-0}" -gt 0 && -n "${remaining:-}" ]]; then
    pct=$(( remaining * 100 / limit ))
  fi
  _claude_cache_ts=$now
  _claude_cache_pct=$pct
  echo "$pct"
}

# ─── Quota: OpenAI API ───────────────────────────────────────────────────────
_openai_cache_ts=0
_openai_cache_pct=100

check_openai_quota() {
  local now; now=$(date +%s)
  (( now - _openai_cache_ts < 300 )) && { echo "$_openai_cache_pct"; return; }

  local api_key; api_key=$(get_openai_api_key)
  if [[ -z "$api_key" ]]; then
    log DEBUG "No OpenAI API key found — using MANUAL_QUOTA_PERCENT"
    echo "$MANUAL_QUOTA_PERCENT"; return
  fi
  log DEBUG "OpenAI quota check using key: ${api_key:0:12}…"

  local hfile; hfile=$(mktemp)
  curl -sf -D "$hfile" \
    -H "Authorization: Bearer $api_key" \
    "https://api.openai.com/v1/models" \
    -o /dev/null 2>/dev/null || true

  local limit remaining reset_str
  limit=$(     grep -i '^x-ratelimit-limit-tokens:'     "$hfile" \
               | awk '{print $2}' | tr -d '\r' | head -1)
  remaining=$( grep -i '^x-ratelimit-remaining-tokens:' "$hfile" \
               | awk '{print $2}' | tr -d '\r' | head -1)
  reset_str=$( grep -i '^x-ratelimit-reset-tokens:'     "$hfile" \
               | awk '{print $2}' | tr -d '\r' | head -1)
  rm -f "$hfile"

  # Convert "6m30s" / "1h0m0s" → ISO-8601 timestamp
  if [[ -n "${reset_str:-}" ]]; then
    local secs=0
    [[ "$reset_str" =~ ([0-9]+)h ]] && secs=$(( secs + ${BASH_REMATCH[1]} * 3600 ))
    [[ "$reset_str" =~ ([0-9]+)m ]] && secs=$(( secs + ${BASH_REMATCH[1]} * 60  ))
    [[ "$reset_str" =~ ([0-9]+)s ]] && secs=$(( secs + ${BASH_REMATCH[1]}       ))
    local re=$(( now + secs ))
    QUOTA_RESET_TIME=$(
      date -u -d "@${re}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
      date -u -r  "${re}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo ""
    )
  fi

  local pct=100
  if [[ -n "${limit:-}" && "${limit:-0}" -gt 0 && -n "${remaining:-}" ]]; then
    pct=$(( remaining * 100 / limit ))
  fi
  _openai_cache_ts=$now
  _openai_cache_pct=$pct
  echo "$pct"
}

# ─── Quota: dispatch & wait ───────────────────────────────────────────────────
get_quota_percent() {
  case "$AI_TOOL" in
    claude|claude-code) check_claude_quota ;;
    codex|openai)       check_openai_quota ;;
    *)                  echo "$MANUAL_QUOTA_PERCENT" ;;
  esac
}

_iso_to_epoch() {
  local iso="$1"
  date -d  "$iso" +%s 2>/dev/null ||
  date -jf '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null ||
  echo $(( $(date +%s) + 1800 ))
}

check_and_wait_quota() {
  local pct; pct=$(get_quota_percent)
  log INFO "Quota: ${BOLD}${pct}%${NC} remaining  (threshold: ${QUOTA_THRESHOLD}%)"
  (( pct >= QUOTA_THRESHOLD )) && return 0

  log WARN "Quota below threshold (${pct}% < ${QUOTA_THRESHOLD}%) — waiting for reset"

  while true; do
    local wait_secs=1800
    if [[ -n "${QUOTA_RESET_TIME:-}" ]]; then
      local re ne; ne=$(date +%s); re=$(_iso_to_epoch "$QUOTA_RESET_TIME")
      wait_secs=$(( re - ne + 60 ))
      (( wait_secs < 60 )) && wait_secs=60
      log INFO "Reset at ${QUOTA_RESET_TIME} — sleeping ${wait_secs}s"
    else
      log INFO "Reset time unknown — rechecking in 30 min"
    fi
    sleep "$wait_secs"

    pct=$(get_quota_percent)
    if (( pct >= QUOTA_THRESHOLD )); then
      log OK "Quota restored (${pct}%) — resuming"
      return 0
    fi
    log WARN "Still at ${pct}% — waiting again"
  done
}

# ─── Issue fetching ───────────────────────────────────────────────────────────
_jq_include_filter() {
  [[ ${#INCLUDE_LABELS[@]} -eq 0 ]] && echo "true" && return
  local f="false"
  for lbl in "${INCLUDE_LABELS[@]}"; do
    f="${f} or ([.labels[].name] | contains([\"${lbl}\"]))"
  done
  echo "(${f})"
}

_jq_exclude_filter() {
  [[ ${#EXCLUDE_LABELS[@]} -eq 0 ]] && echo "true" && return
  local f="true"
  for lbl in "${EXCLUDE_LABELS[@]}"; do
    f="${f} and ([.labels[].name] | contains([\"${lbl}\"]) | not)"
  done
  echo "(${f})"
}

_jq_priority_score() {
  local n=${#PRIORITY_LABELS[@]}
  [[ $n -eq 0 ]] && echo "0" && return
  local expr="0" i score
  for (( i=n-1; i>=0; i-- )); do
    score=$(( n - i ))
    expr="(if ([.labels[].name] | contains([\"${PRIORITY_LABELS[$i]}\"])) then ${score} else ${expr} end)"
  done
  echo "$expr"
}

fetch_issues() {
  # Returns one compact JSON object per line, sorted by: priority desc, number asc
  local raw inc exc prio
  raw=$(gh issue list \
    --repo "$REPO" --state open \
    --json number,title,body,labels,url \
    --limit 100) || return 1

  inc=$(_jq_include_filter)
  exc=$(_jq_exclude_filter)
  prio=$(_jq_priority_score)
  log DEBUG "jq include : $inc"
  log DEBUG "jq exclude : $exc"
  log DEBUG "jq priority: $prio"

  echo "$raw" | jq -c "
    [ .[]
      | select(${inc})
      | select(${exc})
      | . + {priority: ${prio}}
    ]
    | sort_by([-.priority, .number])
    | .[]
  "
}

is_processed()   { [[ "$PROCESSED_ISSUES" == *" $1 "* ]]; }
mark_processed() { PROCESSED_ISSUES="${PROCESSED_ISSUES}$1 "; }

# ─── Git operations ───────────────────────────────────────────────────────────
g() { git -C "$REPO_DIR" "$@"; }

branch_exists_remote() {
  g ls-remote --heads origin "$1" 2>/dev/null | grep -q .
}

create_branch() {
  local branch="$1"
  retry 3 5  g fetch origin --quiet 2>/dev/null
  g checkout -b "$branch" "origin/${PR_BASE_BRANCH}" --quiet
  log DEBUG "Created branch '$branch' from origin/${PR_BASE_BRANCH}"
}

has_changes() { [[ -n "$(g status --porcelain)" ]]; }

commit_and_push() {
  local branch="$1" msg="$2"
  g add -A
  g commit -m "$msg" --quiet
  retry 3 10  g push origin "$branch" --quiet
  log DEBUG "Pushed '$branch'"
}

return_to_base() {
  g checkout "$PR_BASE_BRANCH" --quiet 2>/dev/null || true
}

# ─── PR operations ────────────────────────────────────────────────────────────
create_pr() {
  local branch="$1" num="$2" title="$3" body="$4"
  local pr_body
  pr_body=$(printf \
    'Closes #%s\n\nAutomatically generated fix for: **%s**\n\n---\n\n%s' \
    "$num" "$title" "$body")
  retry 3 10  gh pr create \
    --repo  "$REPO" \
    --title "fix: ${title} (#${num})" \
    --body  "$pr_body" \
    --base  "$PR_BASE_BRANCH" \
    --head  "$branch"
}

wait_for_ci() {
  local pr_num="$1"
  local deadline=$(( $(date +%s) + CI_TIMEOUT ))
  log INFO "Waiting for CI on PR #${pr_num}  (timeout: ${CI_TIMEOUT}s)"

  # Grace period for CI to register after PR creation
  sleep 10

  local dot_count=0
  while (( $(date +%s) < deadline )); do
    local checks_json count
    checks_json=$(gh pr checks "$pr_num" --repo "$REPO" \
                  --json name,state 2>/dev/null) || { sleep "$CI_POLL_INTERVAL"; continue; }

    count=$(echo "$checks_json" | jq 'length' 2>/dev/null || echo 0)

    if (( count == 0 )); then
      log INFO "No CI checks registered — proceeding to merge."
      return 0
    fi

    local has_fail pending
    has_fail=$(echo "$checks_json" | jq -r 'any(.[]; .state == "fail")')
    pending=$(  echo "$checks_json" | jq -r \
                'any(.[]; .state == "pending" or .state == "queued" or .state == "in_progress")')

    log DEBUG "CI count=${count}  fail=${has_fail}  pending=${pending}"

    if [[ "$has_fail" == "true" ]]; then
      local names
      names=$(echo "$checks_json" | \
              jq -r '[.[] | select(.state == "fail") | .name] | join(", ")')
      printf "\n"  # end dot line
      log ERROR "CI failed: ${names}"
      return 1
    fi

    if [[ "$pending" == "false" ]]; then
      printf "\n"
      log OK "All CI checks passed."
      return 0
    fi

    printf "${DIM}.${NC}"; (( dot_count++ )) || true
    sleep "$CI_POLL_INTERVAL"
  done

  printf "\n"
  log ERROR "CI timed out after ${CI_TIMEOUT}s"
  return 1
}

merge_pr() {
  local pr_num="$1"
  retry 3 10  gh pr merge "$pr_num" \
    --repo "$REPO" \
    "--${AUTO_MERGE_METHOD}" \
    --delete-branch
  log OK "PR #${pr_num} merged via ${AUTO_MERGE_METHOD}."
}

# ─── AI tool runners ──────────────────────────────────────────────────────────
_build_prompt() {
  local num="$1" title="$2" body="$3"
  cat <<PROMPT
Fix GitHub issue #${num}: ${title}

Issue description:
${body}

Instructions:
1. Analyze the issue carefully and understand the root cause.
2. Implement the necessary code changes to resolve it.
3. Ensure existing tests still pass; add new tests where appropriate.
4. Follow the project's existing code style and conventions.
5. Do NOT commit, push, or create a PR — only make file changes.
PROMPT
}

run_claude_code() {
  local num="$1" title="$2" body="$3"
  local key; key=$(get_anthropic_api_key)
  log INFO "Running Claude Code on issue #${num}…"
  if [[ -n "$key" ]]; then
    ANTHROPIC_API_KEY="$key" claude --dangerously-skip-permissions \
      -p "$(_build_prompt "$num" "$title" "$body")"
  else
    claude --dangerously-skip-permissions \
      -p "$(_build_prompt "$num" "$title" "$body")"
  fi
}

run_codex() {
  local num="$1" title="$2" body="$3"
  local key; key=$(get_openai_api_key)
  log INFO "Running Codex on issue #${num}…"
  OPENAI_API_KEY="${key}" \
    codex --approval-mode full-auto "$(_build_prompt "$num" "$title" "$body")"
}

run_custom_script() {
  local script="${AI_TOOL#script:}"
  local num="$1" title="$2" body="$3" url="$4"
  log INFO "Running '${script}' on issue #${num}…"
  ISSUE_NUMBER="$num" ISSUE_TITLE="$title" ISSUE_BODY="$body" ISSUE_URL="$url" \
    "$script"
}

run_ai_tool() {
  local num="$1" title="$2" body="$3" url="${4:-}"
  case "$AI_TOOL" in
    claude|claude-code) run_claude_code   "$num" "$title" "$body" ;;
    codex|openai)       run_codex         "$num" "$title" "$body" ;;
    script:*)           run_custom_script "$num" "$title" "$body" "$url" ;;
  esac
}

# ─── Single-issue pipeline ────────────────────────────────────────────────────
process_issue() {
  local issue_json="$1"
  local num title body url
  num=$(  echo "$issue_json" | jq -r '.number')
  title=$(echo "$issue_json" | jq -r '.title')
  body=$( echo "$issue_json" | jq -r '.body // ""')
  url=$(  echo "$issue_json" | jq -r '.url')
  local branch="auto-fix/issue-${num}"

  log STEP "Issue #${num}: ${title}"

  # Guard: skip if a fix branch already exists (interrupted previous run)
  if branch_exists_remote "$branch"; then
    log WARN "Branch '$branch' already exists remotely — skipping."
    _STAT_SKIP=$(( _STAT_SKIP + 1 ))
    return 1
  fi

  # ── 1. Branch
  if ! create_branch "$branch"; then
    log ERROR "Could not create branch '$branch'."
    return_to_base; _STAT_FAIL=$(( _STAT_FAIL + 1 )); return 1
  fi

  # ── 2. AI fix
  if ! run_ai_tool "$num" "$title" "$body" "$url"; then
    log ERROR "AI tool reported failure."
    return_to_base; _STAT_FAIL=$(( _STAT_FAIL + 1 )); return 1
  fi

  # ── 3. Verify output
  if ! has_changes; then
    log WARN "AI tool made no file changes — skipping."
    return_to_base; _STAT_SKIP=$(( _STAT_SKIP + 1 )); return 1
  fi

  # ── 4. Commit & push
  if ! commit_and_push "$branch" "fix: resolve issue #${num} — ${title}"; then
    log ERROR "Commit/push failed."
    return_to_base; _STAT_FAIL=$(( _STAT_FAIL + 1 )); return 1
  fi

  # ── 5. Open PR
  local pr_url pr_num
  if ! pr_url=$(create_pr "$branch" "$num" "$title" "$body"); then
    log ERROR "PR creation failed."
    return_to_base; _STAT_FAIL=$(( _STAT_FAIL + 1 )); return 1
  fi
  pr_num=$(basename "$pr_url")
  log INFO "PR: ${pr_url}"

  # ── 6. Wait for CI
  if ! wait_for_ci "$pr_num"; then
    log WARN "CI did not pass — PR #${pr_num} left open for manual review."
    return_to_base; _STAT_FAIL=$(( _STAT_FAIL + 1 )); return 1
  fi

  # ── 7. Merge
  if ! merge_pr "$pr_num"; then
    log ERROR "Merge failed for PR #${pr_num}."
    return_to_base; _STAT_FAIL=$(( _STAT_FAIL + 1 )); return 1
  fi

  log OK "Issue #${num} resolved and merged."
  return_to_base
  _STAT_OK=$(( _STAT_OK + 1 ))
  return 0
}

# ─── Main loop ────────────────────────────────────────────────────────────────
run() {
  while true; do
    # ── Quota gate
    check_and_wait_quota

    # ── Fetch issues
    log INFO "Fetching open issues from ${BOLD}${REPO}${NC}…"
    local issues_output
    issues_output=$(fetch_issues) || die "Failed to fetch issues from GitHub."

    if [[ -z "$issues_output" ]]; then
      if [[ "$LOOP_MODE" == "true" ]]; then
        log INFO "No matching open issues. Waiting 60s before next check..."
        sleep 60
        continue
      else
        log INFO "No matching open issues. Done."
        break
      fi
    fi

    # ── Dry-run: print and exit
    if [[ "$DRY_RUN" == "true" ]]; then
      printf "\n  ${BOLD}Issues that would be processed:${NC}\n\n"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local n t p lbls
        n=$(    echo "$line" | jq -r '.number')
        t=$(    echo "$line" | jq -r '.title')
        p=$(    echo "$line" | jq -r '.priority')
        lbls=$( echo "$line" | jq -r '[.labels[].name] | join(", ")')
        printf "    ${BOLD}#%-5s${NC}  p=%-2s  %-52s  ${DIM}[%s]${NC}\n" \
               "$n" "$p" "$t" "$lbls"
      done <<< "$issues_output"
      break
    fi

    # ── Pick next unprocessed issue
    local next=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local n; n=$(echo "$line" | jq -r '.number')
      is_processed "$n" || { next="$line"; break; }
    done <<< "$issues_output"

    if [[ -z "$next" ]]; then
      log INFO "All fetched issues processed this run. Done."
      break
    fi

    # ── Pre-task quota re-check
    local pct; pct=$(get_quota_percent)
    if (( pct < QUOTA_THRESHOLD )); then
      log WARN "Quota dropped (${pct}%) — pausing before next task."
      check_and_wait_quota
    fi

    # ── Process
    local n; n=$(echo "$next" | jq -r '.number')
    mark_processed "$n"
    process_issue "$next" || true

    if [[ "$MAX_ISSUES_PER_RUN" -gt 0 ]]; then
      local done=$(( _STAT_OK + _STAT_FAIL + _STAT_SKIP ))
      if (( done >= MAX_ISSUES_PER_RUN )); then
        log INFO "Reached MAX_ISSUES_PER_RUN=${MAX_ISSUES_PER_RUN}. Stopping."
        break
      fi
    fi

    sleep 5
  done
}

# ─── Dependency check ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in git gh jq curl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] && die "Missing required tools: ${missing[*]}"

  gh auth status &>/dev/null \
    || die "GitHub CLI not authenticated. Run: gh auth login"

  case "$AI_TOOL" in
    claude|claude-code)
      command -v claude &>/dev/null \
        || die "claude CLI not found. Install from https://claude.ai/code" ;;
    codex|openai)
      command -v codex &>/dev/null \
        || die "codex CLI not found." ;;
    script:*)
      local s="${AI_TOOL#script:}"
      [[ -x "$s" ]] || die "Custom script not executable: $s" ;;
    *) die "Unknown AI_TOOL value: '$AI_TOOL'" ;;
  esac
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  local total=$(( _STAT_OK + _STAT_FAIL + _STAT_SKIP ))
  printf "\n"
  printf "  ${BOLD}${CYAN}┌──────────────────────────┐${NC}\n"
  printf "  ${BOLD}${CYAN}│  Session Summary         │${NC}\n"
  printf "  ${BOLD}${CYAN}├──────────────────────────┤${NC}\n"
  printf "  ${BOLD}${CYAN}│${NC}  Processed : %-3s         ${BOLD}${CYAN}│${NC}\n" "$total"
  printf "  ${BOLD}${CYAN}│${NC}  ${GREEN}Succeeded${NC} : %-3s         ${BOLD}${CYAN}│${NC}\n" "$_STAT_OK"
  printf "  ${BOLD}${CYAN}│${NC}  ${RED}Failed${NC}    : %-3s         ${BOLD}${CYAN}│${NC}\n" "$_STAT_FAIL"
  printf "  ${BOLD}${CYAN}│${NC}  ${YELLOW}Skipped${NC}   : %-3s         ${BOLD}${CYAN}│${NC}\n" "$_STAT_SKIP"
  printf "  ${BOLD}${CYAN}└──────────────────────────┘${NC}\n"
  printf "\n"
}

# ─── Banner & usage ───────────────────────────────────────────────────────────
banner() {
  printf "\n${BOLD}${CYAN}"
  printf "  ╔══════════════════════════════════════════╗\n"
  printf "  ║       auto-maintainer  %-17s║\n" "v${VERSION}"
  printf "  ║   AI-powered GitHub Issue Resolver      ║\n"
  printf "  ╚══════════════════════════════════════════╝\n"
  printf "${NC}\n"
}

usage() {
  cat <<EOF
${BOLD}Usage:${NC}
  $(basename "$0") [options]

  Run from inside a git repository. The GitHub repo is auto-detected
  from the 'origin' remote URL.

${BOLD}Options:${NC}
  -c, --config FILE   Config file  (default: ~/.config/auto-maintainer/config.sh)
  -n, --dry-run       List matching issues; make no changes
  -q, --quota  PCT    Override initial quota % for manual checker
  -l, --loop          Wait 1 minute and re-check instead of exiting when no issues are found
  -v, --verbose       Show debug output
  -h, --help          Show this help
  -V, --version       Print version

${BOLD}AI tool (set AI_TOOL= in config):${NC}
  claude / claude-code   →  claude --dangerously-skip-permissions -p PROMPT
  codex  / openai        →  codex --approval-mode full-auto PROMPT
  script:/path/to/x.sh   →  Custom script; issue passed via ISSUE_* env vars

${BOLD}API key lookup order (no manual config needed):${NC}
  Claude  →  ANTHROPIC_API_KEY env  →  ~/.claude/settings.json  →  ~/.anthropic/credentials
  Codex   →  OPENAI_API_KEY env     →  ~/.codex/config.json     →  ~/.config/openai/credentials

${BOLD}Examples:${NC}
  cd ~/my-project && $(basename "$0")
  cd ~/my-project && $(basename "$0") --dry-run
  cd ~/my-project && $(basename "$0") --quota 65 --verbose
  cd ~/my-project && $(basename "$0") -c ./project-config.sh
EOF
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  local quota_override=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)  CONFIG_FILE="$2";    shift 2 ;;
      -n|--dry-run) DRY_RUN=true;        shift   ;;
      -q|--quota)   quota_override="$2"; shift 2 ;;
      -l|--loop)    LOOP_MODE=true;      shift   ;;
      -v|--verbose) VERBOSE=true;        shift   ;;
      -h|--help)    usage; exit 0                ;;
      -V|--version) echo "${BIN_NAME} ${VERSION}"; exit 0 ;;
      *) die "Unknown option: $1  (try --help)" ;;
    esac
  done

  # Resolve repo directory first (needed for default config path)
  init_repo_dir

  # Default config location
  if [[ -z "$CONFIG_FILE" ]]; then
    local xdg_cfg="${XDG_CONFIG_HOME:-${HOME}/.config}/${BIN_NAME}/config.sh"
    local repo_cfg="${REPO_DIR}/auto-maintainer.config.sh"
    if   [[ -f "$repo_cfg" ]];  then CONFIG_FILE="$repo_cfg"
    elif [[ -f "$xdg_cfg" ]];   then CONFIG_FILE="$xdg_cfg"
    else die "No config file found. Tried:
    $repo_cfg
    $xdg_cfg
  Run install.sh or pass -c /path/to/config.sh"
    fi
  fi

  load_config "$CONFIG_FILE"

  [[ -n "$quota_override" ]] && MANUAL_QUOTA_PERCENT="$quota_override"

  # Auto-detect repo AFTER config is loaded (config may set REPO explicitly)
  detect_repo
}

# ─── Entry point ──────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  banner

  log INFO "  Repo    : ${BOLD}${REPO}${NC}"
  log INFO "  Tool    : ${BOLD}${AI_TOOL}${NC}"
  log INFO "  Dir     : ${REPO_DIR}"
  log INFO "  Config  : ${CONFIG_FILE}"
  log INFO "  Branch  : ${PR_BASE_BRANCH}  merge: ${AUTO_MERGE_METHOD}"
  log INFO "  Quota   : pause below ${QUOTA_THRESHOLD}%"
  [[ "$LOOP_MODE" == "true" ]] && log INFO "  Loop    : Wait 60s when idle"
  [[ "$DRY_RUN" == "true" ]] && log WARN "  DRY RUN — no changes will be made"
  [[ "$VERBOSE" == "true" ]] && log INFO "  Verbose logging enabled"
  printf "\n"

  check_deps
  acquire_lock
  run
  print_summary
}

main "$@"
