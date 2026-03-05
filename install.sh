#!/usr/bin/env bash
# =============================================================================
#  install.sh — Installer for auto-maintainer
# =============================================================================
#  Online (macOS / Linux):
#    curl -fsSL https://raw.githubusercontent.com/iwangjiaxiang/auto-maintainer/main/install.sh | bash
#
#  From a local clone:
#    ./install.sh
#    sudo ./install.sh --system    # install to /usr/local/bin
#    ./install.sh --uninstall      # remove installed files
# =============================================================================

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly REPO_SLUG="iwangjiaxiang/auto-maintainer"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/main"
readonly BIN_NAME="auto-maintainer"
readonly DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/${BIN_NAME}"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/${BIN_NAME}"

INSTALL_DIR="${HOME}/.local/bin"
UNINSTALL=false

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

info()    { printf "  ${BLUE}·${NC}  %s\n"        "$*"; }
ok()      { printf "  ${GREEN}✓${NC}  %s\n"        "$*"; }
warn()    { printf "  ${YELLOW}!${NC}  %s\n"        "$*"; }
fail()    { printf "  ${RED}✗${NC}  %s\n"           "$*" >&2; }
die()     { fail "$*"; exit 1; }
section() { printf "\n${BOLD}${CYAN}  ── %s${NC}\n" "$*"; }

# ─── Detect online vs local ───────────────────────────────────────────────────
# When piped through curl, BASH_SOURCE[0] is empty or "bash" with no adjacent files.
_self="${BASH_SOURCE[0]:-}"
_self_dir="$(cd "$(dirname "${_self:-/nonexistent}")" 2>/dev/null && pwd || echo "")"

if [[ -f "${_self_dir}/auto_maintainer.sh" ]]; then
  # Running from a local clone
  ONLINE=false
  SRC_SCRIPT="${_self_dir}/auto_maintainer.sh"
  SRC_CONFIG="${_self_dir}/config.example.sh"
else
  # Running via curl | bash — download files first
  ONLINE=true
  SRC_SCRIPT="${DATA_DIR}/auto_maintainer.sh"
  SRC_CONFIG="${DATA_DIR}/config.example.sh"
fi

# ─── Args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)    INSTALL_DIR="/usr/local/bin"; shift ;;
    --dir)       INSTALL_DIR="$2"; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)
      printf "Usage: ./install.sh [--system] [--dir PATH] [--uninstall]\n"
      printf "  or : curl -fsSL %s/install.sh | bash\n" "$RAW_BASE"
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ─── Banner ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}"
printf "  ╔══════════════════════════════════════════╗\n"
printf "  ║       auto-maintainer  installer        ║\n"
printf "  ╚══════════════════════════════════════════╝\n"
printf "${NC}\n"

# ─── Uninstall ────────────────────────────────────────────────────────────────
if [[ "$UNINSTALL" == "true" ]]; then
  section "Uninstalling"
  for dir in "${HOME}/.local/bin" "/usr/local/bin"; do
    local t="${dir}/${BIN_NAME}"
    if [[ -e "$t" || -L "$t" ]]; then rm -f "$t"; ok "Removed $t"; fi
  done
  if [[ -d "$DATA_DIR" ]]; then
    warn "Data directory preserved: ${DATA_DIR}  (remove manually if desired)"
  fi
  if [[ -d "$CONFIG_DIR" ]]; then
    warn "Config preserved: ${CONFIG_DIR}  (remove manually if desired)"
  fi
  printf "\n  ${GREEN}${BOLD}Done.${NC}\n\n"; exit 0
fi

# ─── OS detection ─────────────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
  Darwin) OS_NAME="macOS" ;;
  Linux)  OS_NAME="Linux" ;;
  *)      OS_NAME="$OS"   ;;
esac
info "Platform: ${OS_NAME}"
info "Mode    : $( [[ "$ONLINE" == "true" ]] && echo "online (curl)" || echo "local clone" )"
info "Install : ${INSTALL_DIR}"

# ─── Dependency check ─────────────────────────────────────────────────────────
section "Checking dependencies"

DEPS_OK=true
_require() {
  local name="$1" hint="${2:-install via package manager}"
  if command -v "$name" &>/dev/null; then
    ok "${name}  ($(command -v "$name"))"
  else
    fail "${name} not found — ${hint}"
    DEPS_OK=false
  fi
}
_check() {
  local name="$1" hint="${2:-}"
  if command -v "$name" &>/dev/null; then
    ok "${name}  ($(command -v "$name"))"
  else
    warn "${name} not found${hint:+ — ${hint}}"
  fi
}

_require git  "https://git-scm.com"
_require gh   "https://cli.github.com"
_require jq   "$( [[ "$OS_NAME" == "macOS" ]] && echo "brew install jq" || echo "apt install jq" )"
_require curl "install via package manager"
printf "\n  ${BLUE}AI tools (only the one you configure is required):${NC}\n"
_check claude "https://claude.ai/code"
_check codex  "https://github.com/openai/codex"

${DEPS_OK} || die "Install the missing required tools above, then re-run."

# Bash version check
if (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
  die "Bash 3.2+ required (found ${BASH_VERSION}).
       macOS: brew install bash && sudo bash -c 'echo /opt/homebrew/bin/bash >> /etc/shells'"
fi
ok "bash ${BASH_VERSION}"

# ─── Online: download source files ────────────────────────────────────────────
if [[ "$ONLINE" == "true" ]]; then
  section "Downloading files from GitHub"
  mkdir -p "$DATA_DIR"

  _download() {
    local name="$1" dest="$2"
    info "Downloading ${name}…"
    if command -v curl &>/dev/null; then
      curl -fsSL "${RAW_BASE}/${name}" -o "$dest" \
        || die "Download failed: ${RAW_BASE}/${name}"
    else
      die "curl is required for online installation."
    fi
    ok "  → ${dest}"
  }

  _download "auto_maintainer.sh"  "$SRC_SCRIPT"
  _download "config.example.sh"   "$SRC_CONFIG"
fi

# ─── Install binary ───────────────────────────────────────────────────────────
section "Installing binary"
mkdir -p "$INSTALL_DIR"
chmod +x "$SRC_SCRIPT"

INSTALL_PATH="${INSTALL_DIR}/${BIN_NAME}"
[[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]] && rm -f "$INSTALL_PATH"

if [[ "$ONLINE" == "true" ]]; then
  # Online install: copy (no local repo to link back to)
  cp "$SRC_SCRIPT" "$INSTALL_PATH"
  ok "Installed: ${INSTALL_PATH}"
  info "  (Re-run this curl command to update in the future)"
else
  # Local clone: symlink so git pull automatically updates the binary
  ln -s "$SRC_SCRIPT" "$INSTALL_PATH"
  ok "Installed: ${INSTALL_PATH}  →  ${SRC_SCRIPT}"
  info "  (git pull in the repo will update the binary automatically)"
fi

# ─── Config setup ─────────────────────────────────────────────────────────────
section "Setting up configuration"
mkdir -p "$CONFIG_DIR"
ok "Config directory: ${CONFIG_DIR}"

DEST_CONFIG="${CONFIG_DIR}/config.sh"
if [[ ! -f "$DEST_CONFIG" ]]; then
  cp "$SRC_CONFIG" "$DEST_CONFIG"
  ok "Default config created: ${DEST_CONFIG}"
else
  warn "Config already exists — not overwritten: ${DEST_CONFIG}"
fi

# ─── PATH check ───────────────────────────────────────────────────────────────
section "PATH"
if command -v "$BIN_NAME" &>/dev/null; then
  ok "'${BIN_NAME}' is already in PATH"
else
  warn "'${INSTALL_DIR}' is not in your PATH"
  printf "\n  Add this line to your shell profile:\n\n"

  case "$OS_NAME" in
    macOS)
      printf "    ${BOLD}# ~/.zshrc  (zsh is the default on macOS)${NC}\n"
      printf "    export PATH=\"\${HOME}/.local/bin:\${PATH}\"\n\n"
      printf "  Then reload:  ${BOLD}source ~/.zshrc${NC}\n"
      ;;
    *)
      printf "    ${BOLD}# ~/.bashrc${NC}\n"
      printf "    export PATH=\"\${HOME}/.local/bin:\${PATH}\"\n\n"
      printf "  Then reload:  ${BOLD}source ~/.bashrc${NC}\n"
      ;;
  esac
fi

# ─── GitHub auth check ────────────────────────────────────────────────────────
section "GitHub authentication"
if gh auth status &>/dev/null; then
  gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
  ok "Authenticated as: ${gh_user}"
else
  warn "Not authenticated with GitHub."
  printf "\n  Run:  ${BOLD}gh auth login${NC}\n"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
printf "\n  ${GREEN}${BOLD}Installation complete!${NC}\n\n"
printf "  ${BOLD}Next steps:${NC}\n\n"
printf "  1. Edit your config:\n"
printf "       ${CYAN}${DEST_CONFIG}${NC}\n\n"
printf "  2. Preview which issues would be processed:\n"
printf "       ${BOLD}cd /your/project && ${BIN_NAME} --dry-run${NC}\n\n"
printf "  3. Run for real:\n"
printf "       ${BOLD}cd /your/project && ${BIN_NAME}${NC}\n\n"
