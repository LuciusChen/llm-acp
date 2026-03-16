# 006 — Rewrite: llm-acp → acp-bridge

> Superseded in scope by `007-scope-narrow-to-headless-bridge.md`.
> This record remains as historical context for the initial rewrite away from
> `llm.el`, but its chat-UI direction is no longer the current product scope.

**Date:** 2026-03-16

---

## Background

`llm-acp` was built as an `llm.el` provider: it implemented `llm-chat-async`, `llm-chat-streaming`, and `llm-capabilities` so that any package already using `llm.el` (ellama, magit-gptcommit, gptel-aibo) could point to Claude Code or Codex without code changes.

Within weeks of writing it, the actual usage pattern diverged from that goal:

1. None of the target packages (ellama, magit-gptcommit) were being used. The actual callers were direct Elisp calls wanting a simple `(send message → get text)` function.
2. The only UI being missed was a chat buffer — not llm.el integration, but a standalone `M-x` entry point.
3. gptel was evaluated as a complementary backend path but rejected: gptel's backend protocol assumes HTTP/curl transport at the implementation level. Hooking ACP (stdio) into gptel would require reimplementing the entire HTTP layer in terms of process I/O. Not worth it.

The name `llm-acp` also signalled the wrong thing: it implied the package was a provider *for* llm.el. The real value is the ACP bridge layer, not the llm.el adapter.

---

## Decision

Rewrite as `acp-bridge`:

1. **Remove `(require 'llm)`** and all `cl-defmethod` implementations of llm.el interfaces.
2. **Remove llm.el prompt types**: `llm-chat-prompt`, `llm-chat-prompt-interaction`. Replace with plain strings and `((role . content) ...)` alists.
3. **Add `acp-bridge-request`** — a `cl-defun` programmatic API taking a plain string message with keyword callbacks. No prompt struct construction required by callers.
4. **Add a chat buffer UI** — `acp-bridge-chat` opens `*ACP Bridge[APP@PROJECT]*` with streaming text and a minor mode (`acp-bridge-mode`) bound to `C-c RET`.
5. **Port the session/persistence/dispatch/notification core unchanged** — those layers worked correctly and had no llm.el coupling. Only rename from `llm-acp--` to `acp-bridge--`.

---

## Why llm.el Was Wrong

### The transport mismatch is architectural, not accidental

`llm.el` providers are expected to make HTTP calls (the `llm-request-plz` helper, curl-based internals). The protocol contract includes response callbacks fired from HTTP filter functions. ACP uses stdio and JSON-RPC; the ACP client (`acp.el`) fires callbacks from process filter functions. Making these two worlds meet required wrapping every callback boundary — not a missing feature, but a fundamental impedance mismatch.

### Prompt types added friction for every caller

Every caller had to construct an `llm-chat-prompt` with `make-llm-chat-prompt-interaction`, even for a single-line commit message. The prompt struct also owned history, which forced `llm-acp--prompt->last-message` and `llm-acp--prompt->full-history` to translate llm.el history into ACP's format on every send. The translation was lossy (llm.el supports structured content; ACP wants plain text) and added four functions with no value outside the llm.el compat layer.

### Session history belonged in the caller, not in the prompt struct

`llm.el`'s multi-turn model is: the caller builds a growing `llm-chat-prompt` with each new interaction appended. The provider sees the full list on every call. But ACP sessions already own history on the agent side — so the provider discarded everything except the last user turn. This made `llm-acp` a leaky abstraction: it accepted the full llm.el history contract but only used the tail of it. For new sessions, it re-serialized the full history as text, bypassing the prompt struct entirely.

`acp-bridge` resolves this by making history explicit:
- The chat buffer maintains `acp-bridge--chat-history` and passes `full-history-text` to `acp-bridge--send` only when needed (session expiry fallback).
- Single-turn callers (`acp-bridge-request` with `:new-session t`) pass `message` as both `message` and `full-history-text`. No history management required.

---

## What Was Kept

The session persistence, pending dispatch table, notification handler, and agent init state machine from `llm-acp.el` were correct and are ported without change. The core send flow (ensure-ready → new/resume → do-prompt) is identical; only the signature of `acp-bridge--send` changed (plain strings instead of prompt struct).

---

## Alternatives Considered

### Keep llm.el and add the chat buffer alongside it

This would have worked, but it would have maintained the translation overhead and the llm.el dependency for no benefit. The only callers that need llm.el compat are packages already built on llm.el; direct callers (the primary use case) would continue paying the prompt-struct tax unnecessarily.

### gptel backend

Investigated and rejected. gptel backends are expected to implement `gptel-request` using HTTP/curl. The backend contract does not provide a hook for stdio-based transports. Reverse-engineering gptel's HTTP dispatch to accept a process-filter-based callback would have been more invasive than writing a standalone package.

### llm.el provider + separate `acp-bridge-request`

Keep `llm-acp` as-is and add `acp-bridge-request` as a wrapper on top. Rejected because it doubles the surface area and keeps the llm.el dependency for callers that don't need it. Clean cut is better.

---

## Known Limitations Introduced

- **Chat buffer agent is hardcoded to `:claude`**. A per-buffer agent selector (`M-x acp-bridge-chat-with-codex` or a prefix arg) is deferred.
- **llm.el callers can no longer use this package**. If ellama or magit-gptcommit integration is needed in the future, `llm-acp.el` can be kept as a thin shim on top of `acp-bridge--send`. That shim would be ~30 lines.
- **`acp-bridge-request` has no history replay for multi-turn API callers**. If the session expires mid-conversation, the new session starts without context. Chat buffer callers are unaffected (they replay via `acp-bridge--chat-history`). API callers who need history persistence across session expiry must manage history themselves.
