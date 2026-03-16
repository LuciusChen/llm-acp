# acp-bridge — Product Requirements Document

## Overview

`acp-bridge` is an Emacs Lisp package that provides a small, headless ACP bridge for Claude Code and Codex CLI.

Its primary job is to let Elisp callers send prompts through ACP, reuse agent-side project context and sessions, and receive streaming text responses without depending on HTTP model APIs.

`acp-bridge` is not a chat application. Interactive chat should live in a separate frontend such as `agent-shell`. This package owns the transport, session, and request lifecycle layer.

## Product Positioning

### What it is

- A callable Elisp API for ACP-backed requests
- A session manager keyed by `(app, project)`
- A thin bridge over `acp.el`
- A foundation for replacing some local "model API" usage patterns inside Emacs

### What it is not

- A dedicated chat UI
- An `llm.el` provider
- A `gptel` backend
- A drop-in replacement for remote model APIs in backend/server environments

## Problem

Elisp callers that want AI assistance currently face an awkward choice:

1. Call model HTTP APIs directly and rebuild prompt context, project context, auth, and streaming logic locally.
2. Use a chat-oriented frontend that is optimized for interaction, not for small programmatic calls.
3. Integrate with `llm.el`/`gptel`, which are shaped around HTTP provider abstractions rather than ACP's stdio and session model.

For callers already living inside Emacs, and for users already using Claude Code or Codex, there is a simpler need:

- send a string
- get streamed text / final text back
- optionally reuse the current ACP session for the current project

## Goals

| # | Goal |
|---|------|
| G1 | Provide a stable `acp-bridge-request` API for Elisp callers |
| G2 | Reuse one ACP client process per agent type |
| G3 | Persist one ACP session per `(app, context)` pair |
| G4 | Stream plain-text responses with minimal caller ceremony |
| G5 | Keep the package independent from `llm.el`, `gptel`, and chat-buffer concerns |
| G6 | Evolve toward broader API-replacement scenarios without abandoning ACP-native semantics |

## Non-Goals

- Dedicated chat UI
- `llm.el` compatibility
- `gptel` compatibility
- General backend/service API replacement outside Emacs
- Supporting arbitrary ACP agents beyond Claude Code and Codex

## Current Requirements

### Functional

1. `acp-bridge-request` sends a string prompt and accepts callbacks for chunk, done, and error.
2. The request API may also expose raw ACP session events to callers.
3. The request API supports:
   - `agent`
   - `app`
   - `cwd`
   - `system-prompt`
   - `new-session`
   - `on-event`
   - `on-tool-call`
   - `on-request`
4. Sessions are persisted by `(app . context) -> (agent . session-id)`.
5. Expired sessions are handled by removing the stale session ID and creating a new ACP session.
6. One notification handler is registered per ACP client and dispatches per `sessionId`.
7. ACP permission requests are surfaced to callers and can be answered from Emacs.
8. Interactive commands exist only for session inspection/control:
   - `acp-bridge-new-session`
   - `acp-bridge-delete-session`
   - `acp-bridge-cancel-session`
   - `acp-bridge-set-model`

### Non-Functional

1. No process is started on package load.
2. Initialization is shared across callers for the same agent.
3. Session persistence survives Emacs restarts.
4. The API remains small and string-oriented until richer event support is justified.

## Architecture

### Component Overview

```text
Elisp callers
  -> acp-bridge-request
  -> acp-bridge session lookup / lifecycle
  -> acp.el client
  -> claude-agent-acp / codex-acp
```

### State

- `acp-bridge--agents`: one live ACP client per agent type
- `acp-bridge--pending`: in-flight request table keyed by `session-id`
- `acp-bridge--sessions-cache`: persisted `(app . context)` session mapping cache

### Request Lifecycle

```text
acp-bridge-request
  -> compute context
  -> optionally clear stored session if new-session
  -> ensure ACP client initialized
  -> if stored session exists: session/resume
  -> on resume failure: drop stored session and session/new
  -> session/prompt
  -> session/update agent_message_chunk => on-chunk
  -> prompt success => on-done
  -> prompt failure / agent error => on-error
```

## Public API

```elisp
(acp-bridge-request message
  &key
  (agent        :claude)
  (app          'acp-bridge)
  cwd
  system-prompt
  new-session
  on-chunk
  on-event
  on-tool-call
  on-request
  on-done
  on-error)
```

### Usage Patterns

Single-turn, stateless-ish request:

```elisp
(acp-bridge-request prompt
  :app 'magit
  :new-session t
  :on-done (lambda (text) ...))
```

Session-backed request:

```elisp
(acp-bridge-request "Summarize the section"
  :app 'org
  :on-chunk (lambda (text) ...)
  :on-done  (lambda (text) ...))
```

## Limits of the Current API

The current public API is intentionally narrow. It exposes:

- text in
- streamed text out
- raw `session/update` params out
- merged tool-call state out
- permission requests out
- final text out
- errors

It does not yet expose:

- structured output contracts
- explicit stateless request mode beyond "start a fresh session"

This is acceptable for the current scope, but it is the main gap between `acp-bridge` and a fuller "API replacement layer".

## API Replacement Roadmap

To support more API-like use cases inside Emacs, the next iteration should add:

### R1. Event passthrough

Expose richer ACP events to callers, not just text chunks. This includes:

- normalized tool-call events
- permission requests
- possibly additional raw ACP payloads beyond the current surface

### R2. Host capabilities

Expose ACP client capabilities and related handlers, especially:

- file-system capabilities
- permission handling
- MCP server configuration

### R3. Better request modes

Support clearer request semantics for callers who need:

- fresh-session execution
- reproducible prompts
- explicit per-request settings

### R4. Structured helpers

Add optional helpers for:

- extracting final assistant text
- JSON-only flows
- response post-processing

These should be layered above the ACP bridge, not baked into the transport core.

## Delivery Plan

### Phase 1 — Event Passthrough MVP

Scope:

- add request-level `:on-event` callback
- add merged tool-call state callback
- forward raw ACP `session/update` payloads
- handle ACP incoming requests relevant to request execution, especially permission requests

Acceptance:

1. A caller can observe more than plain text chunks during a request.
2. Tool-related ACP updates can be logged or handled by the caller when exposed by the agent.
3. Permission requests are surfaced instead of disappearing inside the bridge.

Status:

- request-level `:on-event` implemented
- merged tool-call state surfaced via `:on-tool-call`
- `session/request_permission` surfaced via `:on-request`

Remaining work before closing Phase 1:

1. Stabilize the event model across `:on-event`, `:on-tool-call`, and `:on-request`.
2. Add broader tool-call lifecycle coverage:
   - multiple concurrent `toolCallId`s
   - partial updates with missing fields
   - failed / cancelled terminal states
   - late-arriving `content` / `rawOutput`
3. Document the intended caller boundary:
   - use `:on-event` for raw ACP access
   - use `:on-tool-call` / `:on-request` for normalized integration

Phase 2 should begin only after these behaviors are explicit and covered by tests.

### Phase 2 — Host Capability Surface

Scope:

- expose client capability configuration
- expose `mcpServers` in session creation/resume paths
- define the public API boundary for host-side ACP participation

Acceptance:

1. A caller can opt into ACP capabilities without patching internals.
2. MCP server wiring is available from the public API.
3. README examples cover at least one richer-than-text request flow.

Status: **complete**

- `:mcp-servers` added to `acp-bridge-request`; forwarded to `session/new` and `session/resume`
- `acp-bridge-fs-read-capability` and `acp-bridge-fs-write-capability` defcustoms declared in `initialize`
- `fs/read_text_file` auto-handled by the bridge (Emacs file I/O)
- `fs/write_text_file` surfaced to caller via `:on-request`; auto-rejected when no handler
- README updated with MCP server and fs capability examples

### Phase 3 — API Ergonomics

Scope:

- add clearer single-turn helpers
- add optional structured-output helpers
- reduce ceremony for common "replace direct API call" use cases

Acceptance:

1. Single-turn usage does not require repeated keyword boilerplate.
2. JSON-oriented callers have a supported path above the transport layer.
3. The public API remains ACP-native and smaller than a full provider abstraction.

Status: **complete**

- `acp-bridge-query`: thin wrapper over `acp-bridge-request` with `:new-session t`
- `acp-bridge-query-json`: single-turn with JSON system prompt and auto-parsed `:on-done`
- Both functions are autoloaded and documented

## Dependencies

| Package | Role |
|---------|------|
| `acp.el` | ACP transport and JSON-RPC implementation |
| `project.el` | Project root detection |
| `map.el` | JSON/object access helpers |

### External Binaries

| Binary | Install |
|--------|---------|
| `claude-agent-acp` | `npm install -g @zed-industries/claude-agent-acp` |
| `codex-acp` | `npm install -g @zed-industries/codex-acp` |

## Known Limitations

- Only pre-authenticated agents are supported
- General ACP request passthrough beyond permission handling is not implemented
- API callers receive limited structured callbacks; richer ACP surface is still incomplete
- Session reuse is ACP-native, not an exact match for stateless model API semantics
- `fs/write_text_file` auto-write path (without `:on-request`) is not implemented

## Success Criteria

`acp-bridge` is successful if:

1. Emacs packages can replace ad hoc direct model API calls with `acp-bridge-request`.
2. Users can reuse Claude Code / Codex project context without building custom chat frontends.
3. The package stays small and ACP-native while still growing toward richer event passthrough where it materially improves caller ergonomics.
