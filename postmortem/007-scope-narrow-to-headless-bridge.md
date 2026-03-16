# 007 — Narrow Scope to a Headless ACP Bridge

**Date:** 2026-03-16

## Background

After the `llm-acp -> acp-bridge` rewrite, the written product story still
mixed two different goals:

1. a dedicated chat frontend inside Emacs
2. a small programmable ACP bridge for Elisp callers

That combination made the project harder to reason about. The code that exists
today is centered on request sending, session reuse, and session management.
The chat story is both under-implemented and strategically unnecessary because
interactive chat already has better homes, such as `agent-shell`.

At the same time, the more valuable direction for future work is not a custom
chat UI, but broader "API replacement" support for local Emacs callers:
tool-call passthrough, permission handling, richer ACP events, and possibly
MCP-backed host capabilities.

## Decision

Narrow `acp-bridge` to a headless ACP bridge.

- Keep `acp-bridge-request` as the center of the public API
- Keep interactive commands only for session lifecycle management
- Remove chat UI from the README / PRD scope
- Treat separate interactive frontends as external consumers of the bridge
- Prioritize richer ACP event passthrough over any built-in chat experience

## Why

### The existing code already matches this shape

The implemented core is session-oriented transport glue:

- ensure ACP client readiness
- resume or create sessions
- send prompts
- stream text chunks
- manage persisted session IDs

That is a coherent product boundary. A chat UI is not.

### Chat UI is not the differentiator

The unique value of this project is ACP-native programmability inside Emacs,
not another text buffer. A chat frontend can be swapped; the bridge layer is
the reusable part.

### API replacement needs different investment

To replace more ad hoc model-API usage, the package needs:

- richer ACP event exposure
- request/permission passthrough
- MCP and client-capability support
- clearer request semantics for callers

Spending effort on a built-in chat buffer delays those capabilities.

## Alternatives Considered

### Keep both chat UI and bridge as first-class goals

Rejected. This splits attention across two product surfaces with different UX
and testing needs, while only one of them is the real long-term leverage point.

### Delete all previous postmortems and restart the record

Rejected. Earlier records still contain useful reasoning about session keys,
session persistence, system-prompt handling, and cancellation semantics. The
problem is stale scope, not that all prior reasoning is invalid.

### Keep historical postmortems untouched

Rejected. Some records, especially around chat, would continue to mislead
future work if left unqualified.

## Consequences

- README and PRD should describe a headless bridge, not a chat package.
- Historical postmortems should be retained when their reasoning still applies.
- Records whose scope is outdated should be marked as superseded rather than
  silently deleted.
- Future postmortems should focus on API-surface evolution, ACP event
  passthrough, and host capability exposure.
