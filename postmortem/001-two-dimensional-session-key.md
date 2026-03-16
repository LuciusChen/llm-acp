# 001 — Two-Dimensional Session Key: (app . context)

## Background

The original session persistence used a single-dimension key: the `app` symbol
(e.g. `'ellama`, `'magit`). This meant that if the same app was used from two
different projects, both reuses would converge on the same ACP session — the
agent would have mixed context from unrelated codebases.

## Decision

Replace the scalar `app` key with a cons cell `(app . context)`, where
`context` is computed at send-time:

- inside a project (via `project.el`) → `project-root`
- otherwise → `default-directory`

The `:cwd` field on the provider struct becomes an explicit override for
callers that need to pin the context.

## Why

The ACP agent uses the session's working directory to scope its file access and
tool use. Sharing a session across projects means the agent's context is
ambiguous: it may reference files from a previous project. Two dimensions are
necessary because:

- **app** distinguishes conversation purpose (ellama chat vs. magit commit message)
- **context** distinguishes workspace (project-a vs. project-b)

Neither dimension alone is sufficient.

## Alternatives Considered

**Keep app-only key, pass cwd on every prompt** — Rejected. The ACP session is
not stateless; `session/resume` carries the original cwd. Passing a different
cwd on resume would be misleading and unsupported by the protocol.

**Key by cwd alone** — Rejected. Two different apps in the same project would
share a session and thus a conversation history. A commit-message generator and
a chat assistant must not share state.

**Key by (app, cwd) where cwd is from the struct** — Rejected. The struct's
`:cwd` is set at provider creation time, not at send time. If the user moves
between projects without recreating the provider, the key would be stale.
Dynamic context computation at send-time is more correct.

## Trade-offs Accepted

- The eld file format changed and is not backward-compatible with the
  single-key format. Old sessions are silently dropped on first access (resume
  fails, new session starts). This is acceptable.
- Two Emacs instances sharing the same sessions file are not supported. The
  in-memory cache is process-local. This is an acceptable constraint for a
  single-user tool.
