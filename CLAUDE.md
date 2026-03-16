# acp-bridge Development Guide

Elisp best practices distilled from acp.el, clutch, and magit.

## First Principles

- **Question every abstraction**: Before adding a layer, file, or indirection, ask "is this solving a real problem right now?" If the answer is hypothetical, don't add it.
- **Simplify relentlessly**: Three similar lines of code are better than a premature abstraction. A single file is better than five tiny files with unclear boundaries.
- **Delete, don't deprecate**: If something is unused, remove it entirely. No backward-compatibility shims, no re-exports, no "removed" comments.
- **No side effects on load**: Loading `acp-bridge.el` must not start any process, open any connection, or alter Emacs behavior. All activity begins when the user first sends a prompt.

## Architecture

- **One file**: The entire package lives in `acp-bridge.el`. Do not split unless a genuinely distinct responsibility emerges.
- **One client per agent**: `acp-bridge--agents` holds one ACP process per agent type (`:claude`, `:codex`). Never create more than one client for the same agent.
- **One notification handler per client**: Registered once at client creation. Never add handlers inside request callbacks — that is the root cause of handler accumulation bugs.
- **Dispatch table owns per-request state**: All mutable state for an in-flight request (accumulated text, callbacks) lives in `acp-bridge--pending`, keyed by session-id. Never capture mutable state in closures.
- **No llm.el dependency**: `acp-bridge.el` must not `(require 'llm)`. Message types are plain strings; history is `((role . content) ...)` alists.

## Naming

- **Public API**: `acp-bridge-` prefix. No double dash.
- **Internal/private**: `acp-bridge--` double-dash prefix. Never call from outside this file.
- **Predicates**: multi-word names end in `-p` (e.g., `acp-bridge--client-ready-p`).
- **Unused args**: prefix with `_` (e.g., `(_response)`).

## Control Flow

- Avoid deep `let` → `if` → `let` chains. Favor flat, linear control flow using `if-let*`, `when-let*`.
- Use `pcase` for dispatch on agent type or ACP update kind instead of nested `cond` string comparisons.
- Async chains must be continuation-passing (`:on-success` / `:on-failure` lambdas). Never block with `sleep-for` or polling.

## Error Handling

- **`user-error`** for user-caused problems (agent not installed, no session). Does NOT trigger `debug-on-error`.
- **`error`** for programmer bugs only (unknown agent, impossible state).
- **`condition-case`** around ACP response parsing — a malformed notification must not crash the handler.
- ACP `session/resume` failure is recoverable: silently clear the stored session-id and retry with `session/new`. Do not surface this to the user unless the new session also fails.
- Error messages should state what is wrong, not what should be.

## State Management

- **`defvar`** for global tables (`acp-bridge--agents`, `acp-bridge--pending`). Initialize to empty hash tables at load time.
- **`defvar-local`** for per-buffer chat state (`acp-bridge--chat-app`, `acp-bridge--chat-history`, etc.).
- **`defcustom`** for all user-configurable values. Always specify `:type` precisely and `:group 'acp-bridge`.
- Never store per-request state in `defvar` — use the `acp-bridge--pending` dispatch table.
- Session persistence (`(app . context)` → `(agent . session-id)`) is the only state that crosses Emacs restarts. It lives in `acp-bridge-sessions-file` (`.eld` format). An in-memory cache (`acp-bridge--sessions-cache`, sentinel `:unloaded`) is populated lazily and kept in sync via write-through.

## ACP Protocol

- Always send `initialize` before `session/new`. The client state machine (`:uninitialized` → `:initializing` → `:ready`) ensures this even when multiple callers race.
- `session/resume` may fail silently (the agent-side session may have expired). Treat failure as "start fresh", not as an error.
- Only forward the **current message** to the agent via `session/prompt` when resuming. The agent owns conversation history within its session. The `full-history-text` arg to `acp-bridge--send` is only used when opening a new session.
- `session/update` notifications carry `params.sessionId` — always dispatch by this field.
- `session/cancel` is a notification (fire-and-forget), not a request. The session remains alive after cancellation; do NOT remove it from the sessions store.
- `session/set_model` (`acp-make-session-set-model-request`) is a claude-code-acp extension. Document this in the command's docstring.

## Programmatic API (`acp-bridge-request`)

- `message` and `full-history-text` are both set to the caller's message string — the API does not manage history; the ACP session does.
- `new-session t` is the correct pattern for single-turn callers (e.g. magit commit messages). It discards any stored session before sending.
- Callers should provide `:app` to isolate their sessions from other callers.

## Chat Buffer

- Buffer name: `*ACP Bridge[APP@PROJECT]*`. PROJECT is the last path segment of the context directory.
- `acp-bridge--chat-history` is a reverse-chronological list of `(role . content)` pairs.
  - `(reverse (cdr history))` gives the prior turns in chronological order for `acp-bridge--format-history`.
- The response marker (`acp-bridge--chat-response-marker`) is a `t`-type marker set at the start of the assistant response. Streaming chunks delete-then-reinsert from that marker.
- Block a second send while a response is in progress (`acp-bridge--chat-response-marker` non-nil).

## Function Design

- Keep functions under ~30 lines. Extract helpers when a function exceeds this.
- Name helpers to describe WHAT they compute, not WHERE they're called from.
- Interactive commands (`acp-bridge-chat`, `acp-bridge-new-session`, etc.) must be thin wrappers: validate input, call internal function, show feedback via `message`.

## Autoloads

- `;;;###autoload` on: `acp-bridge-request`, `acp-bridge-chat`, `acp-bridge-send`, `acp-bridge-new-session`, `acp-bridge-delete-session`, `acp-bridge-cancel-session`, `acp-bridge-set-model`.
- Never autoload internal functions, `defcustom`, or `defvar`.

## Pre-Submit Review

Before committing:

- **No handler accumulation**: Verify that notification handlers are registered exactly once per client, not inside per-request code paths.
- **No closure-captured mutable state**: In-flight state must be in `acp-bridge--pending`, not in `let`-bound variables captured by async lambdas.
- **Byte-compile clean**: `(byte-compile-file "acp-bridge.el")` must produce zero warnings.
- **Docs in sync**: Any change to configuration keys, binary names, or behavior must update `PRD.md` and `README.md` in the same commit.

## Quality Checks

- `acp-bridge.el` starts with `;;; acp-bridge.el --- ... -*- lexical-binding: t; -*-` and ends with `(provide 'acp-bridge)` / `;;; acp-bridge.el ends here`.
- `(byte-compile-file "acp-bridge.el")` produces no warnings.
- All public functions have docstrings.

## Postmortems

The `postmortem/` directory contains design decision records and lessons learned. **Read them before making significant changes.**

Each file is named `NNN-topic.md` and records: background, decision, rationale, alternatives considered, and known limitations.

**Write a postmortem when:**
- Choosing between non-obvious architectural approaches
- Reverting or abandoning an approach — especially document *why* it was wrong
- Integrating a new ACP agent or changing the session lifecycle
- Discovering a known limitation that is deliberately deferred

**What to write:** focus on *why*, not *what*. The code already shows what was done.
