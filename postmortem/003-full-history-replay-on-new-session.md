# 003 — Full History Replay When Starting a New ACP Session

## Background

The original `llm-acp--prompt->text` always extracted only the last user
message from the `llm-chat-prompt`. This was correct for the normal path
(existing session: the agent already has history), but produced poor results
when a session expired and `llm-acp` silently created a new one: the agent
would receive only the latest message with no prior context.

## Decision

Split the extraction logic into two functions:

- `llm-acp--prompt->last-message` — sends only the latest user turn; used when
  resuming an existing session.
- `llm-acp--prompt->full-history` — formats the entire `llm-chat-prompt`
  (system context + all interactions) as a labelled conversation string; used
  when starting a new session.

`llm-acp--send` computes `last-text` and `full-text` upfront. `full-text` is
only constructed via `llm-acp--prompt->full-history` when there is no existing
session (otherwise `full-text` reuses `last-text` to avoid formatting work).

`llm-acp--resume-then-prompt` receives both texts and falls back to `full-text`
when resume fails, ensuring the new session also gets the full history.

For the degenerate case (single user message, no system context), `full-history`
returns the message text directly — identical to `last-message` — so there is
no superfluous role-label prefix in the common first-turn case.

## Why

The ACP session is the authoritative owner of conversation history. `llm-acp`
does not replicate it. But `llm-chat-prompt` is the `llm.el` caller's source of
truth — it always carries the full history the caller cares about. When a
session expires, replaying `llm-chat-prompt` as the opening prompt of the new
session is the least surprising recovery: the agent sees the same conversation
the caller intended, just in a fresh session.

## Alternatives Considered

**Always send full history** — Rejected. For existing sessions this would
duplicate turns the agent already has, causing confused responses.

**Send full history only on explicit user request** — Rejected. Silent recovery
is the goal; asking the user to retry defeats the purpose.

**Reconstruct history using ACP `session/load`** — Considered but `session/load`
returns the agent's stored transcript, not the caller's. If the session expired
and was garbage-collected server-side, `session/load` would also fail. Replaying
from `llm-chat-prompt` is more reliable.

**Store history in the eld file** — Rejected. This would duplicate state the
caller already manages and grow the persistence file unboundedly.

## Trade-offs Accepted

- The full-history format is plain text with `"User: ..."` / `"Assistant: ..."`
  labels. This is readable but not a formal protocol format. The agent parses it
  as a natural-language conversation, which is appropriate for Claude Code and
  Codex.
- Non-text content blocks (images, etc.) in `llm-chat-prompt` are silently
  dropped. This is an existing limitation of the provider and is acceptable
  until tool-use passthrough is implemented.
- If the caller's `llm-chat-prompt` is very large, the opening prompt of the
  new session will be large too. The 200k-token ACP limit is the practical cap.
