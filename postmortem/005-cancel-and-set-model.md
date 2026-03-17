# 005 — cancel-session, set-model, and condition-case Guard

## Background

Three features were added in one pass:

1. `llm-acp-cancel-session` — interrupt an in-progress agent operation without
   ending the session.
2. `llm-acp-set-model` — switch the model for an existing session mid-stream
   (claude-code-acp extension).
3. `condition-case` guard in `llm-acp--notification-handler` — prevent malformed
   ACP payloads from crashing the handler.

## Decisions

### cancel-session does NOT remove the session from the store

`session/cancel` is an interrupt signal: the session remains active and the
next `session/prompt` will reuse it. Only `session/delete` terminates a
session. Removing the stored session-id on cancel would force an unnecessary
`session/new` on the next send, losing the agent's in-memory conversation
history.

### cancel-session uses `acp-send-notification`, not `acp-send-request`

The ACP spec defines `session/cancel` as a notification (no response
expected). Using `acp-send-request` would register a pending callback that
would never fire, leaking memory. `acp-send-notification` is fire-and-forget.

### set-model uses `read-string`, not `completing-read`

Model IDs are not enumerable — the set changes with agent versions and is not
exposed via ACP introspection. A free-text `read-string` lets the user type
any valid model ID (e.g. `claude-opus-4-6`, `claude-haiku-4-5-20251001`)
without us needing to maintain an allowlist.

### condition-case wraps the entire `when` body

Placing `condition-case` at the outermost level of `llm-acp--notification-handler`
means any error during field extraction, dispatch-table lookup, or callback
invocation is caught. A narrower wrap (e.g. around just the `map-elt` calls)
would leave callback errors unguarded. The fallback is `(message ...)` — loud
enough to surface in `*Messages*`, silent enough not to interrupt Emacs.

## Test Infrastructure Discovery

When using `acp-fakes-make-client`, notifications are dispatched inline during
`acp-fakes--request-sender`. The fake client dispatches via
`(map-elt client :notification-handlers)`, which is populated only by
`acp-subscribe-to-notifications`. Tests that inject an agent as `:ready` via
`llm-acp-test--inject-agent` must also call `acp-subscribe-to-notifications`
on the fake client, or notifications will be silently dropped and the
`complete-cb` will receive `""`.

Fix: `llm-acp-test--inject-agent` now calls `acp-subscribe-to-notifications`
before inserting the entry into `llm-acp--agents`.

## Why

### cancel must not end the session

`session/cancel` is an interrupt, not a termination. The ACP session remains
alive after a cancel: the next `session/prompt` can continue the same
conversation. Removing the session-id on cancel would force a `session/new` on
the next send, throwing away the agent's in-memory history. The correct mental
model is "stop what you're doing, but stay ready" — analogous to `C-g` in
Emacs: it interrupts the current command but does not close any buffer or
connection.

### cancel must use a notification, not a request

The ACP spec defines `session/cancel` as a notification because there is
nothing to respond to: the agent acknowledges the interrupt by stopping, not
by sending a reply. Registering a pending callback (what `acp-send-request`
does) would leak memory, since the callback would never fire. The contract
of `acp-send-notification` — fire-and-forget — exactly matches the protocol
semantics.

### model selection cannot be enumerable

Model IDs are versioned strings that change with every agent release and are
not exposed through ACP introspection. Any hardcoded allowlist would be stale
immediately. The only correct interface is a free-text prompt that accepts any
string the user knows to be valid. Docstring examples (e.g.
`claude-opus-4-6`, `claude-haiku-4-5-20251001`) serve as guidance without
constraining the input.

### condition-case must wrap the whole handler body

A narrow guard (e.g. around only field-extraction calls) would leave callback
invocation errors unguarded. If an error escapes `llm-acp--notification-handler`,
it propagates into the process filter and can crash Emacs's handling of the
underlying stdio process. Wrapping the entire body converts all unhandled errors
into `(message ...)` output — visible in `*Messages*` for debugging, but
harmless to the rest of Emacs.

## Alternatives Considered

**`acp-send-request` for cancel with a no-op `:on-success`** — Rejected.
Registering a request for a notification-only operation is semantically wrong
and would leave an unreachable callback in the pending table if the agent
never sends a response.

**`completing-read` with a hardcoded model list for set-model** — Rejected.
Hardcoded lists go stale; the ACP protocol does not expose model enumeration.
`read-string` with a docstring noting example model IDs is sufficient.

**Narrower `condition-case` around only `map-elt` calls** — Rejected.
Callback errors (e.g. in `llm-acp--pending-append`) would escape the guard.
Wrapping the whole handler body costs nothing.

## Trade-offs Accepted

- `session/set_model` is a claude-code-acp extension and has no effect on
  Codex sessions. This is documented in the command's docstring.
- `acp-send-notification` success is not observable — if the agent ignores the
  cancel, the user has no feedback beyond the `message` confirming the send.
