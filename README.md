# acp-bridge

A lightweight Emacs package that connects Claude Code and Codex CLI to Emacs via the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

`acp-bridge` is a headless, programmatic bridge. It is intended for Elisp callers that want to reuse Claude Code / Codex sessions and project context without talking to model HTTP APIs directly.

It does not provide a dedicated chat UI. For interactive chat, use a separate frontend such as `agent-shell`; `acp-bridge` focuses on the callable transport/session layer.

## Why

- Reuse the Claude Code / Codex subscription you already pay for
- Reuse agent-side project context, tools, and session state instead of rebuilding it over HTTP
- Give Emacs packages a small API for "send string -> stream text / final text"
- Keep the integration independent from `llm.el`, `gptel`, and custom chat buffers

## Current Scope

Implemented today:

- `acp-bridge-request` programmatic API
- One ACP client process per agent type (`:claude`, `:codex`)
- One persisted session per `(app, project)` pair
- Streaming text chunks via callback
- Raw ACP `session/update` events via `:on-event`
- Structured tool-call state via `:on-tool-call`
- ACP permission requests via `:on-request`
- Session lifecycle commands: new, delete, cancel, set model
- Recovery from expired sessions by creating a new session

Not implemented yet:

- General function-call / host-tool passthrough beyond current ACP tool-call updates
- MCP server configuration exposure in the public API
- Non-interactive authentication flow
- Structured output helpers or schema validation

## Requirements

### Emacs packages

- [acp.el](https://github.com/xenodium/acp.el)

### External binaries

| Agent | Binary | Install |
|-------|--------|---------|
| Claude Code | `claude-agent-acp` | `npm install -g @zed-industries/claude-agent-acp` |
| Codex | `codex-acp` | `npm install -g @zed-industries/codex-acp` |

Both binaries must be authenticated before use via their normal login flow.

## Installation

```elisp
(straight-use-package
 '(acp-bridge :host github :repo "LuciusChen/llm-acp"
              :files ("acp-bridge.el")))
```

Then:

```elisp
(require 'acp-bridge)
```

## Programmatic API

```elisp
;; single-turn request
(acp-bridge-request diff-text
  :app 'magit
  :new-session t
  :system-prompt "Conventional Commits format only."
  :on-done (lambda (text) (insert text)))

;; session-backed request
(acp-bridge-request "Summarize the section"
  :app 'org
  :on-chunk (lambda (text) ...)
  :on-event (lambda (event) ...)
  :on-tool-call (lambda (tool) ...)
  :on-request (lambda (request) ...)
  :on-done  (lambda (_) nil))
```

Full signature:

```elisp
(acp-bridge-request message
  &key
  (agent        :claude)    ; or :codex
  (app          'acp-bridge)
  cwd                       ; nil = auto-detect from project root
  system-prompt             ; appended to agent system prompt on session/new
  new-session               ; if t: clear stored session first
  on-chunk                  ; (lambda (accumulated-text))
  on-event                  ; (lambda (raw-session-update-params))
  on-tool-call              ; (lambda (merged-tool-call-state))
  on-request                ; (lambda (request-needing-response))
  on-done                   ; (lambda (final-text))
  on-error)                 ; (lambda (kind msg))
```

For tool-call updates, `:on-tool-call` receives a plist with fields such as:

- `:type` -> `:tool-call`
- `:session-id`
- `:tool-call-id`
- `:title`
- `:kind`
- `:status`
- `:raw-input`
- `:raw-output`
- `:content`
- `:update-kind`
- `:delta`

For `session/request_permission`, `:on-request` receives a plist with:

- `:type` -> `:permission-request`
- `:session-id`
- `:request-id`
- `:tool-call`
- `:options`
- `:respond` -> function taking an `option-id`
- `:cancel` -> function taking no arguments

If no `:on-request` callback is provided, permission requests are auto-cancelled so the agent does not hang waiting for a client response.

## Session Model

Sessions are persisted to `~/.emacs.d/acp-bridge-sessions.eld`.

- Session key: `(app . context)`
- Context: project root via `project.el`, or `default-directory`
- Stored value: `(agent . session-id)`

This keeps different callers and different projects isolated from each other while still reusing the remote ACP session when appropriate.

## Interactive Commands

These commands manage persisted sessions; they are not a chat UI.

| Command | Description |
|---------|-------------|
| `M-x acp-bridge-new-session` | Clear stored session; next request starts fresh |
| `M-x acp-bridge-delete-session` | Send `session/delete` to the agent and clear local record |
| `M-x acp-bridge-cancel-session` | Send `session/cancel`; session remains alive |
| `M-x acp-bridge-set-model` | Switch model mid-session (Claude ACP extension) |

## Configuration

```elisp
(setq acp-bridge-claude-command '("claude-agent-acp"))
(setq acp-bridge-codex-command  '("codex-acp"))
```

## How It Works

```text
acp-bridge-request
  -> compute context (project root or default-directory)
  -> look up stored session for (app, context)
  -> ensure one ACP client exists for the chosen agent
  -> session/resume if possible
  -> otherwise session/new
  -> session/prompt
  -> stream agent_message_chunk via on-chunk
  -> finalize via on-done
```

One notification handler is registered per ACP client and dispatches by `params.sessionId`, which keeps concurrent requests from different apps isolated.

## API Replacement Boundary

`acp-bridge` can replace some local API usage patterns, especially when:

- the caller already runs inside Emacs
- Claude Code / Codex project context is more valuable than raw model access
- session reuse is desirable
- plain text streaming is enough

It is not a drop-in replacement for model HTTP APIs when you need:

- stateless, reproducible request execution
- tool/function calling contracts exposed to the caller
- structured JSON/schema guarantees
- service-to-service or multi-tenant backend integration
- provider-independent request semantics

## Roadmap

Near-term work for broader API-replacement scenarios:

- expose `mcpServers` and client capabilities in the request API
- add higher-level helpers for stateless calls and structured output

## Implementation Checklist

Suggested build order:

- [x] Add `:on-event` callback support and expose raw ACP `session/update` payloads
- [x] Add `:on-tool-call` with merged tool-call state
- [x] Subscribe to ACP incoming requests and surface `session/request_permission`
- [x] Extend the pending-request state so text callbacks and event callbacks can coexist
- [ ] Expose optional `mcp-servers` and client capability settings in `acp-bridge-request`
- [ ] Add a clearer single-turn helper for fresh-session requests
- [ ] Add optional helpers for JSON-only / structured-output flows

Milestone 1: Event passthrough

- Goal: caller can observe tool-call-related ACP events, not just final text
- Outcome: enough to start replacing simple function-calling style local integrations

Milestone 2: Host capability exposure

- Goal: caller can opt into ACP client capabilities and MCP server wiring
- Outcome: bridge can participate in richer ACP workflows instead of only text prompting

Milestone 3: API ergonomics

- Goal: request modes and structured helpers are easy to consume from Elisp
- Outcome: packages can replace ad hoc direct model API calls with less glue code

## License

GPL-3.0-or-later
