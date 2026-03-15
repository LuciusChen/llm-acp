# llm-acp — Product Requirements Document

## Overview

`llm-acp` is an Emacs Lisp package that exposes Claude Code and Codex CLI as an [`llm.el`](https://github.com/ahyatt/llm) provider via the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

Any Emacs package that already uses `llm.el` as its backend (ellama, magit-gptcommit, gptel-aibo, etc.) can switch to `llm-acp` and immediately start using Claude Code or Codex tokens — with no API key management and with full project context available to the agent.

---

## Problem

### Duplicate token spend

Users who subscribe to Claude Code or Codex CLI pay for those tokens. When they use Emacs packages like ellama or magit-gptcommit, those packages make separate API calls (requiring a separate API key and billing account), effectively paying twice for the same capability.

### No project context

Raw API calls send only what the package explicitly includes in the prompt. Claude Code and Codex, by contrast, can read the entire repository, git history, and surrounding files. A commit-message generator backed by a raw API call sees only the diff; one backed by Claude Code can reason about the whole codebase.

### Fragmented session state

Each API call is stateless. Multi-turn interactions (refining a commit message, iterating on a code review) require the client to manually rebuild and re-send history. ACP sessions maintain state natively on the agent side.

---

## Goals

| # | Goal |
|---|------|
| G1 | Let any `llm.el`-consuming package use Claude Code or Codex as its backend |
| G2 | One persistent ACP session per application symbol, surviving Emacs restarts |
| G3 | Stream tokens to the caller as they arrive (no waiting for full response) |
| G4 | Zero duplicate initialization — one ACP client process per agent type, shared across all apps |
| G5 | Safe concurrent use — multiple packages can be active simultaneously without interfering |

---

## Non-Goals

- Providing a chat UI (that is `agent-shell`'s job)
- Supporting ACP agents other than Claude Code and Codex (though the architecture is agent-agnostic)
- Replacing `gptel` or `llm.el` — this is a provider for them, not a competitor
- Tool-use / function-calling passthrough to `llm.el` (future work)

---

## Architecture

### Component overview

```
┌─────────────────────────────────────────────────────┐
│  Emacs packages using llm.el                        │
│  (ellama, magit-gptcommit, gptel-aibo, …)           │
└──────────────────┬──────────────────────────────────┘
                   │  llm-chat-async / llm-chat-streaming
┌──────────────────▼──────────────────────────────────┐
│  llm-acp.el  (this package)                         │
│                                                     │
│  ┌─────────────┐   ┌──────────────────────────────┐ │
│  │ llm-acp     │   │ llm-acp--agents hash table   │ │
│  │ struct      │   │  :claude → agent-entry        │ │
│  │ :agent      │   │  :codex  → agent-entry        │ │
│  │ :app        │   │                              │ │
│  │ :cwd        │   │ Each entry:                  │ │
│  └─────────────┘   │  :client  acp-client         │ │
│                    │  :state   :uninitialized      │ │
│  ┌─────────────┐   │           :initializing       │ │
│  │ pending     │   │           :ready              │ │
│  │ hash table  │   │  :queue   [thunk …]           │ │
│  │ session-id  │   └──────────────────────────────┘ │
│  │  → entry    │                                     │
│  └─────────────┘                                     │
└──────────────────┬──────────────────────────────────┘
                   │  ACP (JSON-RPC over stdio)
       ┌───────────┴───────────┐
       │                       │
┌──────▼──────┐         ┌──────▼──────┐
│ claude-acp  │         │  codex-acp  │
│ (Claude Code│         │  (Codex CLI │
│ ACP server) │         │  ACP server)│
└─────────────┘         └─────────────┘
```

### Session persistence

App → session-id mappings are stored in `~/.emacs.d/llm-acp-sessions.eld`:

```elisp
((magit   . "uuid-aaa-...")
 (ellama  . "uuid-bbb-...")
 (default . "uuid-ccc-..."))
```

On startup, if a session-id exists for the app, `session/resume` is attempted.
On failure (expired session) the entry is cleared and a new session is created
transparently.

Important boundary: the persistence key is currently only the app symbol, not
`(app, cwd)`. That means one app name reuses one ACP session even if it is used
from different projects/directories. This matches the current implementation,
but it is weaker isolation than "one project-aware session per app instance".

### Request lifecycle

```
llm-acp--send
  ↓
llm-acp--ensure-ready          ; init state machine
  :uninitialized → create client, subscribe global handler, send initialize
  :initializing  → push thunk onto queue
  :ready         → call thunk immediately
  ↓
session exists?
  yes → session/resume → session/prompt
  no  → session/new → save session-id → session/prompt
  ↓
llm-acp--pending-register      ; register session-id → callbacks
  ↓
(concurrent paths)
  notification handler          session/prompt on-success
  session/update arrives    →   fires complete-cb with final text
  agent_message_chunk       →
  llm-acp--pending-append   →
  calls partial-cb
```

### Notification dispatch (single global handler)

One handler is registered per ACP client at creation time. It reads
`params.sessionId` from every `session/update` notification and dispatches to
the matching entry in `llm-acp--pending`:

```
notification → method == "session/update"?
                 ↓ yes
               params.sessionId → lookup in llm-acp--pending
                 ↓
               sessionUpdate == "agent_message_chunk"
                 → pending-append: accumulate + call :partial
               sessionUpdate == "agent_error"
                 → pending-error: call :error
```

This ensures:
- No handler accumulation across requests
- Correct isolation between concurrent sessions from different apps

Current implementation note: the handler assumes well-formed ACP
`session/update` payloads. Malformed notifications are not yet wrapped in an
extra defensive `condition-case`, so this is still an implementation boundary
rather than a fully hardened guarantee.

---

## API

### Struct

```elisp
(llm-acp-make
  :agent :claude   ; or :codex
  :app   'magit    ; any symbol; determines which session is reused
  :cwd   nil)      ; nil = auto-detect from (project-current)
```

### Implemented llm.el methods

| Method | Notes |
|--------|-------|
| `llm-name` | Returns e.g. `"Claude/ACP[magit]"` |
| `llm-capabilities` | Returns `'(streaming)` |
| `llm-chat-token-limit` | Returns 200000 |
| `llm-chat-async` | Full response via callback |
| `llm-chat-streaming` | Chunk-by-chunk partial callback + final callback |

### Interactive commands

| Command | Description |
|---------|-------------|
| `llm-acp-new-session` | Clear stored session; next send starts fresh |
| `llm-acp-delete-session` | Send `session/delete` to agent, then clear |

---

## Configuration

```elisp
(require 'llm-acp)

;; Custom ACP server commands (if not on PATH)
(setq llm-acp-claude-command '("claude-acp"))
(setq llm-acp-codex-command  '("codex-acp"))

;; One provider per app
(setq ellama-provider
      (llm-acp-make :agent :claude :app 'ellama))

(setq magit-gptcommit-llm-provider
      (llm-acp-make :agent :claude :app 'magit))

;; Different apps can use different agents
(setq my-review-provider
      (llm-acp-make :agent :codex :app 'review
                    :cwd "/path/to/project"))
```

---

## Dependencies

| Package | Role |
|---------|------|
| `acp.el` (xenodium) | ACP protocol implementation |
| `llm.el` (ahyatt) | Provider interface |
| `project.el` (built-in) | Auto-detect `cwd` from current project |

### External binaries

| Binary | Source | Install |
|--------|--------|---------|
| `claude-acp` | [@zed-industries/claude-agent-acp](https://github.com/zed-industries/claude-agent-acp)，Zed 官方维护，Apache-2.0 | `npm install -g @zed-industries/claude-agent-acp` |
| `codex-acp` | [zed-industries/codex-acp](https://github.com/zed-industries/codex-acp) | `npm install -g @zed-industries/codex-acp` |

---

## Known Limitations & Future Work

### Current limitations

- **No tool-use passthrough**: `llm.el`'s tool-call interface is not yet mapped to ACP tool calls. Packages using tools (function calling) will not work.
- **`llm-chat` (sync) not implemented**: Synchronous chat would block Emacs; callers should use `llm-chat-async` or `llm-chat-streaming`.
- **Authentication**: Only pre-authenticated agents are supported (i.e., `claude` and `codex` must already be logged in via their own CLIs). The optional ACP `authenticate` step is not yet implemented.
- **Session reuse is app-scoped, not cwd-scoped**: session persistence keys only by app symbol. Reusing the same app symbol across multiple projects currently reuses the same ACP session.
- **ACP init failure handling is still minimal**: initialization failures are surfaced via `message`, but there is not yet a richer user-facing recovery model for queued callers.
- **Prompt history**: Only the latest user message is forwarded to the agent. The ACP session owns conversation history on the agent side — this is by design. Session state survives Emacs restarts via persisted session-id and `session/resume`. The only case where history is lost is when a session genuinely expires on the agent side, triggering a transparent `session/new`.

### Future work

| Item | Priority |
|------|----------|
| Tool-use / function-call passthrough | Medium |
| `session/set-model` support (switch model mid-session) | Low |
| Per-app model configuration | Low |
| ACP `authenticate` step for agents requiring login | Low |
| Expose agent thought-process chunks as a separate callback | Low |
| Replay `llm-chat-prompt` history when a session expires and a new one is created | Low |
