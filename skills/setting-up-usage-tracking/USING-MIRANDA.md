# Using Miranda

[Miranda](https://miranda.co) tracks coding-agent token cost and
attributes it to the GitHub issues the work was actually for. This project
has adopted Miranda: the triggers below are commitments the team has made,
not suggestions. When a trigger matches the task you are doing, take the
corresponding action.

Miranda is available two ways, and both apply to you:

- **MCP tools** on the `miranda` server (`tag_session_work_item`,
  `enable_usage_tracking`, `get_my_spend`, `get_my_issue_spend`,
  `get_my_effectiveness`, `get_my_tracking_status`,
  `assign_my_session_work_item`, plus the shared
  `get_info`/`register_project`/`put_project_github_info` — the same rows the
  `gloria` server exposes, since Miranda and gloria share one database).
- **The usage-collector hooks** installed with the Miranda plugin (Claude
  Code, Codex, OpenCode) — they run automatically once the collector's
  `config.json` exists (in `$XDG_CONFIG_HOME/sandgarden`, defaulting to
  `~/.config/sandgarden`); see "Setting up usage tracking" below.

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

## When cost comes up

The other standing trigger, and the one most sessions will never fire. When
the user asks what something cost — their own spend, this issue's cost,
whether the work is getting cheaper — answer from the tools rather than
estimating, and pick by the question:

- **"What have I been spending?"** → `get_my_spend`. One window (`range`:
  `7d`, `30d`, `90d` or `month`, `30d` by default), with the prior period and
  its delta and ranked breakdowns by project, AI tool and model.
- **"What has this issue cost?"** → `get_my_issue_spend`, with `projectSlug`
  and the same issue you declared as `workItemRef`. That answer is the
  issue's **lifetime** cost, not a window's, set against the median of your
  own closed issues of the same type. Omit `workItemRef` to rank your
  costliest issues in that project for the range instead.
- **"Is my work getting cheaper, or better attributed?"** →
  `get_my_effectiveness` (`30d` or `90d`): cost per closed issue and median
  cycle time per GitHub issue type, how much of your spend reached an issue
  at all, cache-hit and output ratios per coding agent, and how much of the
  spend still booked to a pull request actually merged.
- **"Is any of this even being recorded?"** → `get_my_tracking_status`: every
  machine you own and whether its collector is live, stale or silent, plus
  your recent sessions with no confirmed work item.

Every one of these answers about **you**, the authenticated caller. None takes
a user argument and none reports the org's numbers or anyone else's, so they
are safe to call without asking permission. A team or project-wide view is the
Miranda dashboard's job, not an MCP tool's — point the user there instead of
trying to assemble one.

**Repair attribution before quoting any of it.** `get_my_tracking_status`
lists your unattributed and ambiguous sessions, each naming the `projectSlug`
it needs; call `assign_my_session_work_item` (`projectSlug`, `sessionId`,
`workItemRef`) on each one, then re-read. You are the only person who can —
it refuses anyone else's session, an admin's included — and every per-issue
figure above is only as good as the attribution behind it. A session that has
already resolved to an issue is reported back as skipped, never overwritten.

**None of them tells you what THIS session has cost so far.** They read what
the collector has already reported, and the session you are in is still in
flight. The collector's `gloria-usage session` subcommand will answer that
locally, with no round-trip, once it ships; until then, say the current
session's cost isn't available yet rather than estimating it.

## Setting up usage tracking

The Miranda plugin ships hooks (Claude Code, Codex, OpenCode) that transmit
**token usage only** (model names, token counts, timestamps, session ids, a
locally-minted random machine UUID, and this machine's hostname, OS and
architecture so machines are distinguishable in the dashboard — never message
content, prompts, or code). Cursor's hooks are wired too but are currently a no-op — see the
Cursor note below. They are inert until that `config.json` exists, so offer
to set it up if it doesn't — the `setting-up-usage-tracking` skill drives
this end to end.

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
- `get_my_spend` — your own spend for a window (`range`:
  `7d`/`30d`/`90d`/`month`, default `30d`): actual spend with its
  plans-vs-tokens split, the prior period and its delta, how many days you
  ran an agent and your average on those days, your heaviest day, and ranked
  breakdowns by project, AI tool and model. Takes no user argument.
- `get_my_issue_spend` — one issue's lifetime cost, your own share of it, how
  many sessions were booked to it, and GitHub's own state, type and
  timestamps, against the median cost of your own closed issues of that type.
  Requires `projectSlug`. Pass `workItemRef` for a single issue — `range` is
  ignored, because an issue's cost is the whole of its life — or omit it to
  rank your costliest issues in that project for the range.
- `get_my_effectiveness` — your own effectiveness for `30d` or `90d`,
  org-wide across every project: per GitHub issue type, issues closed and
  still open, cost per closed issue and median cycle time; your attribution
  split (unattributed, ambiguous, or still booked to a pull request rather
  than an issue); cache-hit and output-to-input ratios for the period and per
  coding agent; and, of the pull-request-booked spend, what merged versus
  closed unmerged, the cost per merged pull request, and review comments per
  merged pull request. One window governs every figure, so it is a
  within-period rate — use `get_my_issue_spend` for an issue's lifetime cost.
- `get_my_tracking_status` — takes no arguments. Your machines with what each
  has cost and whether its collector is live, stale or has never sent a
  heartbeat, plus your recent sessions with no confirmed work item — their
  cost, branch, working directory, start time, and the `projectSlug` needed
  to repair each one.
- `assign_my_session_work_item` — attach one of your own past sessions to a
  GitHub issue: `projectSlug`, `sessionId` (as `get_my_tracking_status`
  reports it) and `workItemRef` (the same three forms
  `tag_session_work_item` accepts). Self-service only — anyone else's session
  is refused, an admin's included.

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
