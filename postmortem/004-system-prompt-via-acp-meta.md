# 004 — Provider-Level System Prompt via ACP _meta, Not Text Injection

## Background

Users of `llm-acp` may want to attach persistent instructions to a specific
provider instance — for example, enforcing a commit message format for a
`magit-gptcommit` provider, or setting a tone constraint for an `ellama`
provider. The `llm-chat-prompt-context` field carries the calling package's
system prompt, but there is no provider-level override.

A naive approach would prepend extra text to every outgoing prompt or to the
`full-history` string when creating a new session.

## Decision

Add a `:system-prompt` field to the `llm-acp` struct. When non-nil, pass it
to `acp-make-session-new-request` via `:meta '((systemPrompt . ((append . "..."))))`.
This uses ACP's native `_meta.systemPrompt.append` mechanism, which appends the
string to the agent's built-in default system prompt at session creation time.

The field is threaded through `llm-acp--send` →
`llm-acp--new-session-then-prompt` and is also forwarded when
`llm-acp--resume-then-prompt` falls back to a new session after expiry.

## Why

**ACP `_meta.systemPrompt.append` is the correct layer.**
The system prompt is a property of the session, not of any individual message.
Injecting it via `_meta` at `session/new` means:

1. It takes effect once at session creation and is owned by the agent for the
   lifetime of the session — consistent with how the agent's own default
   instructions work.
2. It does not appear in the conversation history and cannot accidentally
   be interpreted as a user turn.
3. It does not interact with `llm-acp--prompt->full-history`'s replay logic:
   replaying history does not re-send the system prompt as text, avoiding
   duplication.

## Alternatives Considered

**Prepend to every `session/prompt` call** — Rejected. The system prompt would
appear as a user message on every turn, polluting the conversation history and
likely confusing the agent.

**Prepend as `"System: ..."` inside `llm-acp--prompt->full-history`** — Rejected
for the same reason on the new-session path, and also because it only applies
when `full-history` is used, not on subsequent sends to an existing session.

**Use `_meta.systemPrompt` (replace, not append)** — Considered. Replacing the
default system prompt gives full control but risks losing important agent
defaults (e.g., safety instructions, tool-use instructions). Append is the
safer default; users who need full replacement can work around this by not
relying on the default.

**Store the system prompt in the session file and re-apply on resume** —
Rejected. `session/resume` does not accept `_meta`; the system prompt is set
at creation and maintained by the agent. If a session expires and a new one is
created, the `:system-prompt` is applied again naturally via the fallback path.

## Trade-offs Accepted

- The `:system-prompt` only takes effect when a new session is created.
  For long-lived sessions it is applied once and then maintained by the agent.
  There is no mechanism to change the system prompt of an already-running
  session (ACP does not support this). Users who change `:system-prompt` must
  run `llm-acp-new-session` to pick it up.
- `_meta.systemPrompt.append` is an ACP extension; its availability depends on
  the agent. Claude Code supports it; other future agents may not. The field
  is ignored if unsupported, which is acceptable.
