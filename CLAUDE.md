# llm-acp Development Guide

Elisp best practices distilled from llm.el, acp.el, and clutch.

## First Principles

- **Question every abstraction**: Before adding a layer, file, or indirection, ask "is this solving a real problem right now?" If the answer is hypothetical, don't add it.
- **Simplify relentlessly**: Three similar lines of code are better than a premature abstraction. A single file is better than five tiny files with unclear boundaries.
- **Delete, don't deprecate**: If something is unused, remove it entirely. No backward-compatibility shims, no re-exports, no "removed" comments.
- **No side effects on load**: Loading `llm-acp.el` must not start any process, open any connection, or alter Emacs behavior. All activity begins when the user first sends a prompt.

## Architecture

- **One file**: The entire package lives in `llm-acp.el`. Do not split unless a genuinely distinct responsibility emerges (e.g., a separate transport layer).
- **One client per agent**: `llm-acp--agents` holds one ACP process per agent type (`:claude`, `:codex`). Never create more than one client for the same agent.
- **One notification handler per client**: Registered once at client creation. Never add handlers inside request callbacks — that is the root cause of handler accumulation bugs.
- **Dispatch table owns per-request state**: All mutable state for an in-flight request (accumulated text, callbacks) lives in `llm-acp--pending`, keyed by session-id. Never capture mutable state in closures.

## Naming

- **Public API**: `llm-acp-` prefix. No double dash.
- **Internal/private**: `llm-acp--` double-dash prefix. Never call from outside this file.
- **Predicates**: multi-word names end in `-p` (e.g., `llm-acp--client-ready-p`).
- **Unused args**: prefix with `_` (e.g., `(_response)`).

## Control Flow

- Avoid deep `let` → `if` → `let` chains. Favor flat, linear control flow using `if-let*`, `when-let*`.
- Use `pcase` for dispatch on agent type or ACP update kind instead of nested `cond` string comparisons.
- Async chains must be continuation-passing (`:on-success` / `:on-failure` lambdas). Never block with `sleep-for` or polling.

## Error Handling

- **`user-error`** for user-caused problems (agent not installed, no session). Does NOT trigger `debug-on-error`.
- **`error`** for programmer bugs only (missing required argument, impossible state).
- **`condition-case`** around ACP response parsing — a malformed notification must not crash the handler.
- ACP `session/resume` failure is recoverable: silently clear the stored session-id and retry with `session/new`. Do not surface this to the user unless the new session also fails.
- Error messages should state what is wrong, not what should be (e.g., `"ACP session/new failed"` not `"Must have a session"`).

## State Management

- **`defvar`** for global tables (`llm-acp--agents`, `llm-acp--pending`). Initialize to empty hash tables at load time.
- **`defcustom`** for all user-configurable values. Always specify `:type` precisely and `:group 'llm-acp`.
- Never store per-request state in `defvar` — use the `llm-acp--pending` dispatch table.
- Session persistence (app → session-id) is the only state that crosses Emacs restarts. It lives in `llm-acp-sessions-file` (`.eld` format). Read lazily, write immediately on change.

## ACP Protocol

- Always send `initialize` before `session/new`. The client state machine (`:uninitialized` → `:initializing` → `:ready`) ensures this even when multiple callers race.
- `session/resume` may fail silently (the agent-side session may have expired). Treat failure as "start fresh", not as an error.
- Only forward the **latest user message** to the agent via `session/prompt`. The agent owns conversation history within its session.
- `session/update` notifications carry `params.sessionId` — always dispatch by this field, never by insertion order or global state.

## llm.el Provider Interface

- Implement `llm-chat-async` and `llm-chat-streaming`. Do not implement `llm-chat` (sync) — it would block Emacs.
- `llm-capabilities` must return `'(streaming)` so callers know to prefer streaming.
- The `llm-chat-prompt` passed by callers may contain full conversation history. Extract only the last user interaction via `llm-acp--prompt->text`. The ACP session maintains its own history.
- Never mutate the `llm-chat-prompt` struct passed by the caller.

## Function Design

- Keep functions under ~30 lines. Extract helpers when a function exceeds this.
- Name helpers to describe WHAT they compute, not WHERE they're called from.
- Interactive commands (`llm-acp-new-session`, `llm-acp-delete-session`) must be thin wrappers: validate input, call internal function, show feedback via `message`.

## Autoloads

- `;;;###autoload` only on interactive commands (`llm-acp-new-session`, `llm-acp-delete-session`).
- Never autoload internal functions, `defcustom`, or `defvar`.

## Pre-Submit Review

Before committing significant changes:

- **No handler accumulation**: Verify that notification handlers are registered exactly once per client, not inside per-request code paths.
- **No closure-captured mutable state**: In-flight state must be in `llm-acp--pending`, not in `let`-bound variables captured by async lambdas.
- **Byte-compile clean**: `(byte-compile-file "llm-acp.el")` must produce zero warnings.
- **Docs in sync**: Any change to configuration keys, binary names, or behavior must update `PRD.md` in the same commit.

## Quality Checks

- `llm-acp.el` starts with `;;; llm-acp.el --- ... -*- lexical-binding: t; -*-` and ends with `(provide 'llm-acp)` / `;;; llm-acp.el ends here`.
- `(byte-compile-file "llm-acp.el")` produces no warnings.
- All public functions have docstrings.

## Postmortems

The `postmortem/` directory contains design decision records and lessons learned. **Read them before making significant changes.**

Each file is named `NNN-topic.md` and records: background, decision, rationale, alternatives considered, and known limitations.

**Write a postmortem when:**
- Choosing between non-obvious architectural approaches (e.g., single global handler vs. per-request handler)
- Integrating a new ACP agent or changing the session lifecycle
- Reverting or abandoning an approach — especially document *why* it was wrong
- Discovering a known limitation that is deliberately deferred

**What to write:** focus on *why*, not *what*. The code already shows what was done. The record must explain why this approach was chosen over alternatives, what was tried and rejected, and what trade-offs were accepted.
