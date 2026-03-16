# 002 — Session Value Stores Agent; In-Memory Cache

## Background

### Agent storage

The original session value was a bare `session-id` string. The interactive
command `llm-acp-delete-session` needed to know which ACP client (`:claude` or
`:codex`) to send `session/delete` to, so it required the user to specify the
agent via an interactive prompt — a poor UX that could easily be wrong.

### I/O

`llm-acp--session-get`, `set`, and `remove` each called `llm-acp--sessions-read`
or `llm-acp--sessions-write` directly. Every send triggered at least one file
read, and every session mutation triggered a read-then-write cycle.

## Decision

**Session value**: change from `session-id` string to `(agent . session-id)`
cons cell. The agent is recorded when the session is created and looked up when
the session is deleted.

**Cache**: introduce `llm-acp--sessions-cache` initialized to `:unloaded`
(a sentinel, not `nil`). `llm-acp--sessions-ensure` loads the file once on
first access. All mutations update the cache and flush to disk (write-through).
`llm-acp--sessions-flush` replaces the old `llm-acp--sessions-write`.

## Why

**Agent in value**: the agent is a property of the session, not of the lookup
key. Storing it alongside the session-id makes `llm-acp-delete-session` fully
self-contained — it can locate the right ACP client without any user input.

**Cache sentinel `:unloaded` vs `nil`**: an empty session list `'()` is a valid
cache state (all sessions cleared). Using `nil` as the "not loaded" sentinel
would cause `(unless nil ...)` to reload the file every time after all sessions
are removed. The `:unloaded` keyword is unambiguous.

**Write-through vs. lazy flush**: lazy flush (e.g., on Emacs exit) risks
losing session-ids if Emacs crashes. Write-through ensures the eld file is
always consistent with the in-memory state. The cost is one file write per
mutation; mutations are rare (one per new session).

## Alternatives Considered

**Store agent in the key** — Rejected. The key identifies a slot in the session
table; mixing the agent into the key would mean `(ellama/claude . /path)` and
`(ellama/codex . /path)` are separate slots. In practice one app uses one agent
consistently, so this adds complexity for no gain.

**Plist value `(:agent :claude :session-id "uuid")`** — Considered but
rejected in favor of the simpler cons cell. The value has exactly two fields
and plist would add overhead without benefit.

**Lazy flush on Emacs exit via `kill-emacs-hook`** — Rejected as described
above (crash safety). Write-through is simpler and safer.

## Trade-offs Accepted

- The eld file format changed again (value is now a cons, not a bare string).
  Old files silently produce a wrong session-id on first access, resume fails,
  and a new session is started. Acceptable.
- The cache is never explicitly invalidated except by the process itself.
  External edits to the eld file are ignored until Emacs restarts. Acceptable
  for a single-user, single-instance tool.
