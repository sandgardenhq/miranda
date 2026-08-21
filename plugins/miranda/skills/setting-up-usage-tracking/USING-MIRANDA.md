# Using Miranda

[Miranda](https://miranda.fi) tracks coding-agent token cost and
attributes it to the GitHub issues the work was actually for. This project
has adopted Miranda: the triggers below are commitments the team has made,
not suggestions. When a trigger matches the task you are doing, take the
corresponding action.

Miranda is available two ways, and both apply to you:

- **MCP tools** on the `miranda` server (`tag_session_work_item`,
  `enable_usage_tracking`, `get_project_cost_summary`, plus the shared
  `get_info`/`register_project`/`put_project_github_info` — the same rows the
  `gloria` server exposes, since Miranda and gloria share one database).
- **The usage-collector hooks** installed with the Miranda plugin (Claude
  Code, Codex, OpenCode) — they run automatically once
  `~/.gloria/config.json` exists; see "Setting up usage tracking" below.

## Start of every session

One cheap check, done as early as possible — before other work, and
regardless of what the task turns out to be:

**Declare the work item, and keep it current.** Identify the GitHub issue
this session is working on and call `tag_session_work_item` with it before
you start working. Do this silently — do not ask the user to confirm a match
you are confident in. Work down this list and stop at the first hit:

1. an issue number in the user's request (`#391`, "issue 391", an issue URL);
2. an issue named earlier in this conversation as the thing being worked on;
3. an issue number in the current branch name (`feature/foo-123`, `123-foo`,
   `issue-123`) — the usual case in Conductor-style setups, where each
   workspace and branch is scoped to one issue;
4. the issue closed by an open PR for the current branch
   (`gh pr view --json closingIssuesReferences`) — only worth the round-trip
   when 1-3 found nothing.

Skip it only when no issue genuinely applies (pure exploration, chores with
no tracked issue). Never invent a ref just to have one.

**Then declare again whenever the answer could have changed.** This is a
standing obligation for the whole session, not a one-time step at the start.
Re-call `tag_session_work_item` when the branch is renamed, when the user
names a different issue, when a PR is opened against a different issue, or
when you discover mid-session that the real work item is another one. Your
declaration outranks every signal collected automatically, so it is the
**only** thing that can correct a session already credited to the wrong
issue — a stale declaration is not neutral, it silently keeps the session's
entire cost on the wrong issue. The call is session-local (transcript only,
no database round-trip), so calling it again costs nothing, and the most
recent call always wins.

## Setting up usage tracking

The Miranda plugin ships hooks (Claude Code, Codex, OpenCode) that transmit
**token usage only** (model names, token counts, timestamps, session ids, and
a locally-minted random machine UUID — never message content, prompts, or
code). Cursor's hooks are wired too but are currently a no-op — see the
Cursor note below. They are inert until `~/.gloria/config.json` exists, so
offer to set it up if it doesn't — the `setting-up-usage-tracking` skill
drives this end to end.

## MCP tools reference

All tools run as the authenticated user against their active organization.
Reads need `inventory:read` (any member); writes need `inventory:write`.

- `get_info` — org id/name/slug. Cheap; call it first when you need org
  context or to check the `miranda` MCP server is reachable.
- `register_project`, `put_project_github_info` — register this repo as a
  gloria.dev/Miranda project (the same rows either server writes).
- `tag_session_work_item` — declare the GitHub issue this session is working
  on (bare issue number, `gh:482`, or a full issue URL). Session-local — it
  writes only to this session's own transcript, never the database — the
  local usage collector reads it back out and reports it for per-issue token
  cost attribution. Call it as soon as the issue is known, and **again**
  every time the work item changes; the most recent declaration wins and
  outranks every automatically-collected signal. See "Start of every
  session".
- `enable_usage_tracking` — mint a write-only, org-scoped Clerk API key and
  return `{ apiBaseUrl, ingestToken }` for this machine's collector. See
  "Setting up usage tracking".
- `get_project_cost_summary` — one project's usage cost: totals for a window
  plus a by-issue breakdown of confirmed, tracked-issue cost.

## First-time and recovery

- **No work item applies to this session** — skip `tag_session_work_item`;
  its cost simply won't attribute to an issue. Don't guess a ref just to have
  one. If one becomes clear later, declare it then — a late declaration
  still attributes the session's whole cost, including what was already
  spent.
- **You declared the wrong issue** — call `tag_session_work_item` again with
  the right one. The later declaration supersedes the earlier one and moves
  the already-credited cost with it. There is no way to clear a declaration
  other than replacing it, and no lower-ranked signal (a branch rename, a
  PR's `Closes #N`) can override one — so correcting it is on you.
- **MCP auth fails** — the user must log in to the `miranda` server: Claude
  Code `/mcp` → miranda → authenticate; Codex `codex mcp login miranda`;
  OpenCode follows its MCP auth flow. Until then, `tag_session_work_item`
  and the other tools above are unavailable — mention it and continue
  without them.
- **This file is missing or contradicts the tools you see** — trust the live
  MCP server, and offer to re-run `setting-up-usage-tracking`.

## Codex, OpenCode, and Cursor

**Codex:** the Codex plugin manifest (`.codex-plugin/plugin.json`) declares
the same `Stop`/`SessionStart` hooks Claude Code uses, pointing at the same
collector. Codex's own hooks documentation describes `Stop` as a genuine
turn-level event, distinct from `SessionStart`, with a payload shape
(`session_id`/`transcript_path`/`cwd`) that matches Claude Code's — so once
that plugin path fires, `hook-stop` handles it correctly: it detects a Codex
rollout file by name and parses it with the Codex parser instead of Claude
Code's. This is still not empirically confirmed against a live Codex
install, so treat it as expected-but-unverified rather than a guarantee.

As a manual fallback (or on a Codex-only machine that hasn't installed the
plugin), point `notify` in `~/.codex/config.toml` at the collector download
stub directly:

```toml
notify = ["sh", "/path/to/plugins/miranda/collector/stub.sh", "hook-notify"]
```

`notify` fires on every turn completion and carries a `thread-id` +
`cwd` JSON payload. `hook-notify` resolves the one rollout file for that
`thread-id` and syncs only it — the same lightweight, single-file path
`hook-stop` gives Claude Code, never the full multi-source sweep. A
malformed payload, or a `thread-id` with no matching rollout file yet (e.g.
the very first turn of a brand new session), falls back to the full sweep
automatically, so this is always at least as correct as pointing `notify` at
`hook-session-start` directly — which still works, just does more work than
necessary on every turn.

**OpenCode:** the Miranda OpenCode plugin (`.opencode/plugins/miranda.js`)
wires `session.created` and `session.idle` to trigger the same collector
sweep — this ships automatically with the plugin, no manual step needed.

**Cursor:** the Cursor plugin wires `stop`/`sessionStart`/`sessionEnd` hooks
too, but they call the collector's `hook-cursor` entrypoint, which is a
**deliberate no-op**. Cursor hook payloads carry no token usage or cost data,
and Cursor's own local session storage is unreliable for it (missing cache
tokens, mostly-zeroed counts on current versions) — the accurate source is
the Team/Enterprise Admin API, which has no collector adapter yet. Be honest
about this status: Cursor sessions do not contribute usage data today, even
though the hooks are wired.
