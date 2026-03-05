<div align="center">

<img src="header.svg" alt="auto-maintainer header" width="600"/>

**English** | [简体中文](README.zh-CN.md)


**🤖 Your Full-Auto AI Open Source Maintainer | AI-powered GitHub Issue Resolver**

[![Version](https://img.shields.io/badge/version-v1.1.0-blue.svg?style=flat-square)](https://github.com/iwangjiaxiang/auto-maintainer/releases)
[![Language](https://img.shields.io/badge/language-Bash-4EAA25.svg?style=flat-square&logo=gnu-bash&logoColor=white)](https://github.com/iwangjiaxiang/auto-maintainer)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](https://makeapullrequest.com)

</div>

<br/>

<!-- DEMO PLACEHOLDER -->

> 💡 **auto-maintainer** is a smart daemon that runs inside any Git repository. It automatically picks up open Issues, hands the context to an AI coding tool (like Claude Code or OpenAI Codex), commits the fix, opens a PR, waits for CI, and merges it. **100% hands-free**, with built-in intelligent quota management.

---

## ✨ Features

| 🎯 **Zero-Config Out-of-the-Box** | 🔑 **Smart Key Discovery** |
| :--- | :--- |
| Parses `owner/repo` from `git remote origin` automatically. No tedious init required. | Intelligently discovers API keys from config files; no env-var setup needed. |
| 🛠 **Multi-Tool/Script Expandable** | 🚦 **High-Avail Auto Rate-Limiting** |
| Native support for Claude Code and OpenAI Codex, or mount **any custom shell script**. | Live captures API rate limits & quota; auto-sleeps/wakes up to precisely control API budget. |
| 🔄 **Industrial PR Lifecycle** | 🛡 **Robust Recovery Mechanisms** |
| **Branch → AI Fix → Commit → Create PR → Poll CI → Auto-Merge**. | Restores Base branch safely; auto-retries network anomalies; file-locks prevent concurrency drops. |
| 🏷 **Dynamic Issue Scheduler** | 👀 **Dry-Run Sandbox** |
| Supports prioritized ordering via `Priority` labels and `Include/Exclude` filtering. | Zero-intrusion preview mode to check your to-be-resolved Issue queue without worries. |

---

## 🚀 Quick Start

### 1. Prerequisites

auto-maintainer values simplicity. You only need the following basic dependencies (most UNIX-like systems have these built-in):
- `bash` (3.2+) 
- `git`
- `gh` (GitHub CLI, be sure to run `gh auth login` beforehand)
- `jq` and `curl`
- **Core Brain**: AI CLI clients like `claude` (Claude Code) or `codex`.

### 2. One-Liner Installation

We tailored an elegant installation script for you:

```bash
# macOS / Linux users can pipe directly to bash
curl -fsSL https://raw.githubusercontent.com/iwangjiaxiang/auto-maintainer/main/install.sh | bash
```

*(Want to install system-wide? Append `| sudo bash -s -- --system` instead.)*

### 3. Ignition 🛫️

`cd` into the repository you want to maintain, and run:

```bash
# 1. Switch to your main branch
cd ~/my-awesome-project

# 2. Pre-flight check (highly recommended): Preview what the AI will tackle
auto-maintainer --dry-run

# 3. Ready to roll, let the AI work for you!
auto-maintainer

# 4. (Optional) Run continuously as a daemon, polling every minute
auto-maintainer --loop
```

---

## 📂 Project Structure

```text
auto-maintainer/
├── auto_maintainer.sh      # 🚀 Core Controller: handles rate-limits and full PR lifecycle
├── install.sh              # 📦 One-click installer & deployment wizard
├── config.example.sh       # ⚙️ Modular config: supports project/global overrides
├── README.md               # 📖 The geeky docs you are currently reading
├── README.zh-CN.md         # 📖 Simplified Chinese documentation
└── header.svg              # 🖼️ Project header graphic
```

---

## ⚙️ Advanced Configuration

The geek spirit lies in mastering the details. You can elegantly control the AI's behavior via configuration files.

<details>
<summary><b>Click to expand detailed config (config.sh)</b></summary>

Config file fallback order (First Found Wins):
1. Local scope: `<git-root>/auto-maintainer.config.sh`
2. Global scope: `~/.config/auto-maintainer/config.sh`

```bash
# ── AI Engine Driver ──────────────────────────────────────────────────────────────────
AI_TOOL="claude"        # Options: claude | claude-code | codex | openai | script:/path/to/my-tool.sh

# ── Smart Label Scheduler (Filters) ───────────────────────────────────────────────────
INCLUDE_LABELS=("bug" "good first issue")     # Matches ANY to queue (OR); Empty = all issues
EXCLUDE_LABELS=("wontfix" "duplicate")        # Skips issue if ANY matches

# ── Priority Ordering Network (Highest → Lowest) ──────────────────────────────────────
PRIORITY_LABELS=("priority:critical" "priority:high" "priority:medium")

# ── Quota & Concurrency Governance ────────────────────────────────────────────────────
QUOTA_THRESHOLD=30              # Sleeps when remaining API quota drops below this (%)
MANUAL_QUOTA_PERCENT=100        # Safeguard fallback when API Key is undiscoverable
MANUAL_QUOTA_RESET_HOURS=5      # Healing cooldown (Hours) when quota hits limit
CLAUDE_MAX_WEEKLY_USAGE=""      # Skip issue processing if 7-day usage percentage exceeds this

# ── CI & Auto-Merge Strategies ────────────────────────────────────────────────────────
PR_BASE_BRANCH="main"           # Base branch to guard
AUTO_MERGE_METHOD="squash"      # Github weapon of choice: squash | merge | rebase
CI_TIMEOUT=1800                 # Max patience for CI (30 minutes)
CI_POLL_INTERVAL=30             # Status poll frequency (Seconds)

# ── Safety Perimeter ──────────────────────────────────────────────────────────────────
MAX_ISSUES_PER_RUN=0            # Limit max issues hunted per script run (0 = Unlimited)
```

</details>

<br>

<div align="center">
  <sub>Built with ❤️ and 🤖 for the Open Source Community.</sub>
</div>
