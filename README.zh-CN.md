<div align="center">

<img src="header.svg" alt="auto-maintainer header" width="600"/>

[English](README.md) | **简体中文**

**🤖 你的全自动 AI 开源维护者 | AI-powered GitHub Issue Resolver**

[![Version](https://img.shields.io/badge/version-v1.1.0-blue.svg?style=flat-square)](https://github.com/iwangjiaxiang/auto-maintainer/releases)
[![Language](https://img.shields.io/badge/language-Bash-4EAA25.svg?style=flat-square&logo=gnu-bash&logoColor=white)](https://github.com/iwangjiaxiang/auto-maintainer)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](https://makeapullrequest.com)

</div>

<br/>

<!-- DEMO PLACEHOLDER -->

> 💡 **auto-maintainer** 是一个运行在任何 Git 仓库中的智能后台进程。它能够自动接管开启的 Issues，将上下文递交给 AI 编程工具（如 Claude Code 或 OpenAI Codex），自动提交修复、发起 PR、等待 CI 并且最终合并。**全程无需人工干预**，内置智能配额管理。

---

## ✨ 核心特性 / Features

| 🎯 **零配置开箱即用** | 🔑 **密钥智能发现** |
| :--- | :--- |
| 自动解析 `git remote origin` 提取 `owner/repo`，告别繁琐初始化。 | 智能探测搜索主流工具配置文件，免手动配置环境变量。 |
| 🛠 **多生态/脚本拓展** | 🚦 **高可用智能流控** |
| 原生支持 Claude Code/OpenAI Codex，更可挂载 **任意自定义 Shell 脚本**。 | 实时捕获 API 速率及配额指标，自动休眠/唤醒，精准控制 API 开销。 |
| 🔄 **PR 工业级生命周期** | 🛡 **强悍的异常恢复机制** |
| **分支建立 → AI 修复 → 提交 → 发起 PR → 轮询 CI 状态 → 自动合并**。 | 自动恢复 Base 分支状态；应对网络异常自动重试；文件锁防止并发冲突。 |
| 🏷 **动态 Issue 调度器** | 👀 **Dry-run 预览沙盒** |
| 支持使用优先级别化（Priority）标签排序和黑白名单（Include/Exclude）过滤。 | 零入侵预览模式，毫无顾虑地预检当前将要处理的 Issue 队列。 |

---

## 🚀 快速开始 / Quick Start

### 1. 环境准备

auto-maintainer 崇尚极简，你只需要确保系统拥有以下基础依赖（多数类 Unix 系统已自带）：
- `bash` (3.2+) 
- `git`
- `gh` (GitHub CLI，请提前配置 `gh auth login`)
- `jq` 及 `curl`
- **核心大脑**: `claude` (Claude Code) 或 `codex` 等 AI CLI 客户端。

### 2. 一键极速安装

我们为你准备了优雅的安装脚本：

```bash
# macOS / Linux 用户可直接通过管道执行
curl -fsSL https://raw.githubusercontent.com/iwangjiaxiang/auto-maintainer/main/install.sh | bash
```

*(想要安装至系统全局？追加参数 `| sudo bash -s -- --system` 即可。)*

### 3. 点火起飞 🛫️

切入你想要维护的仓库目录，直接运行：

```bash
# 1. 切换到你的项目主干
cd ~/my-awesome-project

# 2. 预检队列（非常推荐的习惯）：看看 AI 将要接手哪些 Bug 和 Feature
auto-maintainer --dry-run

# 3. 准备就绪，让 AI 替你打工！
auto-maintainer

# 4. (可选) 持续后台运行，每分钟自动轮询新 Issue
auto-maintainer --loop
```

---

## 📂 项目结构 / Project Structure

```text
auto-maintainer/
├── auto_maintainer.sh      # 🚀 核心主控逻辑：包含流控、PR 周期的完整调度
├── install.sh              # 📦 一键安装探测与部署向导
├── config.example.sh       # ⚙️ 模块化配置示例：支持项目级/全局级动态覆写
├── README.md               # 📖 英文主文档
├── README.zh-CN.md         # 📖 你现在正在阅读的中文文档
└── header.svg              # 🖼️ 项目视觉头图
```

---

## ⚙️ 高阶玩法：自定义配置 / Advanced Configuration

极客精神在于掌控细节。你可以通过编辑配置文件精巧地操控 AI 在特定场景下的行为模式。

<details>
<summary><b>点击展开查看详细配置项 (config.sh)</b></summary>

配置文件优先选取顺序（First Found Wins）：
1. 局部作用域：`<git-root>/auto-maintainer.config.sh`
2. 全局作用域：`~/.config/auto-maintainer/config.sh`

```bash
# ── AI 引擎驱动 ───────────────────────────────────────────────────────────────────
AI_TOOL="claude"        # 可选项: claude | claude-code | codex | openai | script:/path/to/my-tool.sh

# ── 智能标签调度 (Label Filters) ───────────────────────────────────────────────────
INCLUDE_LABELS=("bug" "good first issue")     # 匹配其一则入列 (OR); 留空则无差别处理
EXCLUDE_LABELS=("wontfix" "duplicate")        # 匹配任何一个则无视该 Issue

# ── 权重排序网络 (Highest → Lowest) ────────────────────────────────────────────────
PRIORITY_LABELS=("priority:critical" "priority:high" "priority:medium")

# ── Quota & 并发管治 ───────────────────────────────────────────────────────────────
QUOTA_THRESHOLD=30              # 余量低于此阈值 (%) 时，挂起休眠
MANUAL_QUOTA_PERCENT=100        # API Key 未探测到时的安全熔断值
MANUAL_QUOTA_RESET_HOURS=5      # 熔断后的自愈冷却时间 (Hours)

# ── CI & 自动化集成策略 ─────────────────────────────────────────────────────────────
PR_BASE_BRANCH="main"           # 默认守卫的 Base 目标分支
AUTO_MERGE_METHOD="squash"      # Github 兵器库: squash | merge | rebase
CI_TIMEOUT=1800                 # CI 检测耐心上限 (30 分钟)
CI_POLL_INTERVAL=30             # HTTP 轮询频次 (Seconds)

# ── 安全防线 ───────────────────────────────────────────────────────────────────────
MAX_ISSUES_PER_RUN=0            # 爆破控制：限制单次脚本运行最多猎杀的 Issue 数量 (0 = Unlimited)
```

</details>

<br>

<div align="center">
  <sub>Built with ❤️ and 🤖 for the Open Source Community.</sub>
</div>
