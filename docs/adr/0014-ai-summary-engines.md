# AI meeting summaries via the user's own Claude Code / Codex CLI (macOS, 0.1.9)

After a meeting transcript is written, sezish can hand it to a locally installed
Claude Code or Codex CLI — the user's own tool on the user's own subscription —
which maintains a knowledge vault of interlinked markdown cards (meeting, contact,
project, decision; Obsidian-style wikilinks; hub `_index.md`) inside the user's
notes folder. sezish never ships, proxies or bills a model for this.

Decisions:
- **Two engines, user's choice, full setup in-app.** Settings pane detects the CLI
  (`--version` + official login-state probes), installs a missing one (Claude: the
  official `install.sh`; Codex: a pinned GitHub-release tarball into
  `~/Library/Application Support/sezish/bin`), and drives the login (Claude:
  `auth login --claudeai` over plain pipes, system browser, paste-code fallback;
  Codex: the official `app-server` JSON-RPC — authUrl / device-code). The user
  never sees a terminal.
- **ToS posture.** Anthropic's docs prohibit third parties from *offering
  Claude.ai login* or *routing requests through plan credentials*; the January
  2026 enforcement hit tools that extracted OAuth tokens and called the API with
  their own harness. sezish deliberately does neither: it installs the official,
  unmodified CLI, the user signs into their own account through the CLI's own
  flow, requests are made by the official binary on the user's machine, no
  pooling, no limit evasion, and the app never reads Keychain/auth.json — only
  the official status commands. Accepted risk, decided by the owner 2026-07-30;
  the Claude adapter can degrade to detect-only with a single switch if
  enforcement ever demands it.
- **Isolation.** Our Codex install gets a private `CODEX_HOME`
  (`…/sezish/codex-home`, tokens in Keychain via `cli_auth_credentials_store`);
  a user-installed codex keeps its own `~/.codex` untouched. Claude runs with
  `--safe-mode --strict-mcp-config`, a fixed tool set (no Bash/network), cwd =
  the vault, and `ANTHROPIC_API_KEY` scrubbed from the child env so the
  subscription always pays, never a stray API key. Codex runs
  `--sandbox workspace-write --cd <vault>` (writes confined to the vault).
- **Idempotency is the app's, not the agent's.** A summary marker is appended to
  the meeting md by sezish after a verified success; the prompt never mentions
  the marker syntax. Marked meetings are skipped.
- **Field-verified.** Live runs against claude 2.1.220 found and fixed three
  contract gaps fake-CLI tests cannot see (variadic `--add-dir` swallowing the
  prompt; the json envelope being an event ARRAY; a line-count transcript
  heuristic mis-skipping short meetings). Rule for future adapters: one live run
  per adapter is part of review.

Ships as 0.1.9 (build 10). Windows unaffected per
[0015](0015-independent-version-line.md).
