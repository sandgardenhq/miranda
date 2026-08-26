---
name: setting-up-usage-tracking
description: Use when installing the Miranda plugin into a repo ("set up token tracking", "enable usage tracking", "install miranda"), when a repo is missing .miranda/USING-MIRANDA.md or the miranda section in CLAUDE.md/AGENTS.md, or after a Miranda plugin update to refresh a stale doc — copies the canonical USING-MIRANDA.md agent doc into the repo, wires an evergreen Miranda section into the agent instruction files (with the user's permission), and mints the per-machine usage-collector credential. Idempotent; safe to re-run.
---

# Setting Up Usage Tracking

## Overview

Wire Miranda into the current repo so every coding agent that works here
declares the GitHub issue it's working on and this machine's token usage
gets collected. Two files carry that:

1. **`.miranda/USING-MIRANDA.md`** — the agent playbook, copied verbatim
   from the `USING-MIRANDA.md` that sits next to this SKILL.md (the skill's
   base directory). Committed to the repo.
2. **A marked section in the repo's agent instruction files** (`CLAUDE.md`
   and/or `AGENTS.md`) that points unconditionally at the doc. The section is
   evergreen — it names no features, so it never changes across Miranda
   releases; only the doc does.

Then, once those are wired, mint the per-machine collector credential so the
hooks the Miranda plugin already installed actually start reporting usage.

Never modify the user's files without showing them exactly what will change
and getting a yes first.

## The instruction-file section

Insert this text exactly, markers included. The markers are how re-runs find
and replace the section instead of duplicating it.

```markdown
<!-- miranda:start -->

## Miranda

This project uses [Miranda](https://miranda.co) to track coding-agent
token cost and attribute it to the GitHub issues the work was for.

Before starting work in this repo, read `.miranda/USING-MIRANDA.md`. It
explains the one thing required at the start of every session — declaring
the work item — plus the Miranda MCP tools available to you. Treat it as a
commitment the team has made, not a suggestion.

<!-- miranda:end -->
```

## Workflow

### 1. Detect state

- Find the repo root (`git rev-parse --show-toplevel`; fall back to the
  working directory if not a git repo).
- Locate the shipped doc: the `USING-MIRANDA.md` in this skill's base
  directory. If it is missing, stop and tell the user the plugin install
  looks broken — do not synthesize the doc from memory.
- Check what already exists at the repo root:
  - `.miranda/USING-MIRANDA.md` — present?
  - `CLAUDE.md`, `AGENTS.md` — which exist, and does each already contain a
    `<!-- miranda:start -->` ... `<!-- miranda:end -->` block?
  - The collector's `config.json` — present? Look in **both** places, in
    this order:
    1. `$XDG_CONFIG_HOME/sandgarden/config.json`, defaulting to
       `~/.config/sandgarden/config.json` when `XDG_CONFIG_HOME` is unset;
    2. `~/.gloria/config.json` — the pre-rename location. A machine set up
       before the rename still has its credential here; the collector
       migrates it automatically on its next run, so this counts as
       "already enabled" too.

    Either one present means usage tracking is already enabled on this
    machine (per-machine, not per-repo) and step 5 is a no-op — say so
    rather than re-minting a key.

### 2. Propose and ask permission — once

Tell the user precisely what will happen, in one message, and ask a single
yes/no. Cover only the actions actually needed, e.g.:

- create (or replace) `.miranda/USING-MIRANDA.md`;
- insert the Miranda section into `CLAUDE.md` and `AGENTS.md` (or "replace
  the existing Miranda section in ...");
- create `AGENTS.md` containing the section, when neither instruction file
  exists;
- mint a usage-tracking credential for this machine, if not already present.

If everything is already current, say so and skip to step 6. If the user
declines the file edits, stop — do not partially apply.

### 3. Write the doc

Copy the shipped `USING-MIRANDA.md` to `.miranda/USING-MIRANDA.md`
**verbatim** (create the `.miranda/` directory if needed). Do not edit,
reformat, or "improve" the content — refreshes must stay a pure file copy.

### 4. Wire the instruction files

For each of `CLAUDE.md` and `AGENTS.md` that exists at the repo root:

- If it contains a marker block, replace everything from
  `<!-- miranda:start -->` through `<!-- miranda:end -->` (inclusive) with
  the section above.
- Otherwise append the section at the end of the file, preceded by one blank
  line.

If neither file exists, create `AGENTS.md` containing only the section
(AGENTS.md is the cross-agent standard; Claude Code reads it too).

### 5. Enable token-usage tracking

If the collector has no `config.json` in **either** location (checked in
step 1):

1. Call the `miranda` MCP tool **`enable_usage_tracking`** (optionally
   passing `machineLabel`, e.g. the machine's hostname, if the user consents
   to naming the key). It mints a write-only, org-scoped Clerk API key and
   returns `{ apiBaseUrl, ingestToken }` plus write instructions.
2. Write `$XDG_CONFIG_HOME/sandgarden/config.json` — `~/.config/sandgarden/config.json`
   when `XDG_CONFIG_HOME` is unset — directly from the tool result, merging
   with any existing keys in the file. The directory is per-machine, not
   per-repo, and shared with the gloria plugin if that's also installed:

   ```json
   {
     "apiBaseUrl": "<apiBaseUrl from the tool result>",
     "ingestToken": "<ingestToken from the tool result>"
   }
   ```

   **Never echo the `ingestToken` into the conversation, logs, or any other
   file** — write it straight to the config file. The secret is shown
   exactly once; a compromised or lost key is revoked from the Clerk
   organization settings, and re-running the tool mints a fresh one.

   Work-item cost attribution needs no config beyond this: the collector
   resolves which gloria/Miranda project a session belongs to itself, per
   session, from that session's own `git remote` — never from a value in
   this file, so one machine works correctly across as many
   gloria-registered repos as the developer has checked out. The collector
   needs no runtime install: the plugin's first hook fire downloads a
   compiled, checksum-verified collector binary for this platform (~50 MB,
   once per collector release) and caches it under `bin/` in that same
   directory.

   **Manual fallback (MCP not connected on this machine):** any org member
   can mint the key from a machine that _does_ have the `miranda` MCP server
   connected (the credential is per-machine, so mint one per machine), or an
   org admin can create an API key with scope `usage:ingest` for the
   organization in Clerk and supply it the same way. Have the user write the
   file themselves — never ask them to paste the secret into the chat.

From the next Claude Code session on, the plugin's hooks report usage
automatically — and the session-start sweep also collects **Codex and
OpenCode** usage from this machine's local session stores, so no further
wiring is needed when Claude Code runs here regularly. See
`USING-MIRANDA.md`'s "Codex, OpenCode, and Cursor" section for per-agent
notes.

### 6. Report

Summarize what changed (files created/updated, section inserted where,
usage tracking configured or already present) and suggest committing the
changes, e.g. `chore: wire miranda agent doc into instruction files`.

## Idempotency rules

- Re-running with identical content is a no-op; say "already current".
- Marker blocks are always replaced in place, never duplicated. If a file
  somehow contains multiple marker blocks, replace the first and remove the
  rest, and mention it.
- Never touch anything outside the marker block in an instruction file, and
  never edit any other file.
- Never re-mint a usage-tracking credential when the collector already has a
  `config.json` in either location from step 1 (including the pre-rename
  `~/.gloria/config.json`) — offer to add `machineLabel` or rotate only if
  the user asks.

## When to suggest this skill proactively

- The user just installed the Miranda plugin in a repo with no
  `.miranda/USING-MIRANDA.md` → offer initial setup.
- The user asks about token cost, usage tracking, or per-issue cost
  attribution and this machine has no collector `config.json` in either
  location → offer to set it up.
