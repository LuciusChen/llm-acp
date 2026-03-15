# llm-acp

An [llm.el](https://github.com/ahyatt/llm) provider that connects to Claude Code and Codex CLI via the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

Any Emacs package that uses `llm.el` as its backend — ellama, magit-gptcommit, gptel-aibo, etc. — can switch to `llm-acp` and immediately use Claude Code or Codex tokens, with full project context and persistent sessions.

## Why

- **No duplicate billing**: reuse the Claude Code / Codex subscription you already pay for, instead of maintaining a separate API key
- **Project context**: Claude Code can read your entire repo, git history, and surrounding files — a commit-message generator backed by `llm-acp` sees far more than just the diff
- **Persistent sessions**: conversation history is maintained on the agent side and survives Emacs restarts; each app gets its own reused ACP session

## Requirements

### Emacs packages

- [acp.el](https://github.com/xenodium/acp.el)
- [llm.el](https://github.com/ahyatt/llm)

### External binaries

| Agent | Binary | Install |
|-------|--------|---------|
| Claude Code | `claude-acp` | `npm install -g @zed-industries/claude-agent-acp` |
| Codex | `codex-acp` | `npm install -g @zed-industries/codex-acp` |

Both binaries must be authenticated before use (`claude` / `codex` login flow).

## Installation

```elisp
;; With straight.el
(straight-use-package
 '(llm-acp :host github :repo "LuciusChen/llm-acp"))
```

Then add to your config:

```elisp
(require 'llm-acp)
```

## Usage

Create one provider per application. Each app gets its own persistent ACP session.

```elisp
;; ellama — long-form chat, sessions survive restarts
(setq ellama-provider
      (llm-acp-make :agent :claude :app 'ellama))

;; magit-gptcommit — project-aware commit messages
(setq magit-gptcommit-llm-provider
      (llm-acp-make :agent :claude :app 'magit))

;; use Codex for a different app
(setq my-review-provider
      (llm-acp-make :agent :codex :app 'review))
```

The `:cwd` field defaults to the current project root. Override if needed:

```elisp
(llm-acp-make :agent :claude :app 'myapp :cwd "/path/to/project")
```

### Custom binary paths

```elisp
(setq llm-acp-claude-command '("claude-acp"))
(setq llm-acp-codex-command  '("codex-acp"))
```

## Session management

Sessions are persisted to `~/.emacs.d/llm-acp-sessions.eld`. On the next send after an Emacs restart, the stored session-id is used to resume the existing conversation via `session/resume`.

Important boundary: persistence is currently keyed only by app symbol, not by
`(app, cwd)`. Reusing the same app symbol across multiple projects/directories
will currently reuse the same ACP session.

| Command | Description |
|---------|-------------|
| `M-x llm-acp-new-session` | Clear the stored session for an app; next send starts a fresh one |
| `M-x llm-acp-delete-session` | Cancel the session on the agent side and clear the local record |

## How it works

```
llm-acp--send
  └─ llm-acp--ensure-ready        init state machine (once per agent)
       └─ session exists?
            yes ─ session/resume ─┐
            no  ─ session/new   ──┴─ session/prompt
                                       │
               ┌───────────────────────┘
               │  (concurrent)
    notification handler              on-success callback
    session/update arrives       →    fires complete-cb
    agent_message_chunk          →
    llm-acp--pending-append      →
    calls partial-cb (streaming)
```

A single notification handler is registered per ACP client at startup. It reads `params.sessionId` from every `session/update` notification and dispatches to the matching in-flight request in `llm-acp--pending`. This ensures correct isolation between concurrent requests from different apps.

Current implementation boundary: the handler assumes well-formed ACP
`session/update` payloads. Malformed notifications are not yet wrapped in an
extra defensive `condition-case`.

## Implemented llm.el methods

| Method | Notes |
|--------|-------|
| `llm-name` | e.g. `"Claude/ACP[magit]"` |
| `llm-capabilities` | `'(streaming)` |
| `llm-chat-token-limit` | 200000 |
| `llm-chat-async` | full response via callback |
| `llm-chat-streaming` | chunk-by-chunk partial + final callback |

## Known limitations

- `llm-chat` (synchronous) is not implemented — it would block Emacs
- Tool-use / function-call passthrough is not yet supported
- Only pre-authenticated agents are supported; the ACP `authenticate` step is not implemented
- Session persistence is app-scoped, not cwd-scoped
- ACP init failure handling is still minimal

## License

GPL-3.0-or-later
