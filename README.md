<h1 align="center">Miranda</h1>

<p align="center">
  <strong>Track coding-agent token cost and attribute it to the GitHub issues it was for.</strong>
</p>

---

This is the plugin marketplace for **[Miranda](https://miranda.co)** —
Sandgarden's token-cost tracking product, built on [gloria.dev](https://gloria.dev)'s
platform. One repo serves multiple coding agents —
[Claude Code](https://docs.claude.com/en/docs/claude-code/plugins),
[OpenAI Codex](https://developers.openai.com/codex/plugins),
[OpenCode](https://opencode.ai), and [Cursor](https://cursor.com) — from a
single published source. Install the `miranda` plugin and your agent gets
the usage-tracking setup skill, the token-usage collector hooks, and the
hosted gloria.dev MCP server's scoped `/miranda` tools — no gloria plugin
required.

> **Extracted from the `gloria` marketplace.** Token-usage tracking used to
> ship inside the general-purpose [`sandgardenhq/gloria`](https://github.com/sandgardenhq/gloria)
> plugin. It now lives here so a developer can adopt Miranda without adopting
> the rest of Gloria. If you previously used the `gloria` plugin's
> token-usage tracking, install `miranda` here to keep it working — see
> [Migrating from the gloria marketplace](#migrating-from-the-gloria-marketplace)
> below.

## What is Miranda?

Miranda tracks coding-agent token usage per machine and attributes cost to
the GitHub issue the work was actually for, so a team can see what a feature
or bug fix cost in agent time, not just an undifferentiated total. It shares
its backend (database, MCP worker, jobs) with gloria.dev — a project
registered in gloria is already a project in Miranda.

## What's in the `miranda` plugin

Installing the plugin gives your agent the setup skill, wires up the usage
collector, and registers the hosted MCP server. (Cursor's marketplace has no
individual-user self-service install command yet — see its section below for
the working-today local-plugin install.)

| Component                             | What it does                                                                                                                                                     |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Skill** `setting-up-usage-tracking` | Wires `.miranda/USING-MIRANDA.md` and an evergreen instruction-file section into a repo, then mints this machine's usage-collector credential.                   |
| **The usage collector**               | Downloaded and checksum-verified on first hook fire (~50 MB, once per release); reports token usage (model, token counts, timestamps — never message content).   |
| **MCP server** `miranda`              | The gloria.dev MCP server's scoped `/miranda` endpoint: `tag_session_work_item`, `enable_usage_tracking`, `get_project_cost_summary`, plus project registration. |

The plugin registers the remote **gloria.dev MCP server** at
`https://mcp.gloria.dev/miranda` (Streamable HTTP) under the name
**miranda**. The server is OAuth-protected; the first request triggers a
one-time browser sign-in.

## Install

Pick your agent. Each command below is run from inside that agent unless
noted.

### Claude Code

```text
/plugin marketplace add sandgardenhq/miranda
/plugin install miranda@miranda
/mcp                       # complete sign-in for the "miranda" server
```

The first command registers this marketplace; the second installs the
`miranda` plugin (its skill, collector hooks, and the scoped gloria.dev MCP
server) — restart Claude Code if prompted. `/mcp` completes the one-time
OAuth sign-in.

Now ask your agent:

```text
Set up usage tracking in this repo
```

That invokes the `setting-up-usage-tracking` skill, which wires
`.miranda/USING-MIRANDA.md` into your project and mints this machine's
usage-collector credential.

### OpenAI Codex

```bash
codex plugin marketplace add sandgardenhq/miranda   # in your shell
```

Then, inside Codex, run `/plugins` and install **miranda**. Finally,
complete the one-time OAuth handshake with the remote MCP server:

```bash
codex mcp login miranda                             # in your shell
```

Now ask your agent:

```text
Set up usage tracking in this repo
```

That invokes the `setting-up-usage-tracking` skill, which wires
`.miranda/USING-MIRANDA.md` into your project and mints this machine's
usage-collector credential.

### OpenCode

OpenCode has no marketplace — add Miranda as a plugin in your `opencode.json`
(global `~/.config/opencode/opencode.json` or a project-local
`opencode.json`), then restart OpenCode:

```json
{ "plugin": ["miranda@git+https://github.com/sandgardenhq/miranda.git"] }
```

OpenCode installs the plugin, which registers the setup skill, the scoped
MCP server, and the collector sweep on session start/idle. The first MCP
call opens a one-time browser sign-in — follow OpenCode's own MCP auth
prompt. Pin a version with a git ref (`…/miranda.git#v0.1.0`).

Now ask your agent:

```text
Set up usage tracking in this repo
```

That invokes the `setting-up-usage-tracking` skill, which wires
`.miranda/USING-MIRANDA.md` into your project and mints this machine's
usage-collector credential.

### Cursor

Cursor shipped its own plugin marketplace in February 2026 (Cursor 2.5), and
this repo ships a real Cursor plugin (`.cursor-plugin/`) bundling the same
skill and MCP server as the Claude/Codex plugin. Cursor has no
individual-user self-service "add a marketplace repo" command yet, so clone
this repo and symlink the plugin into Cursor's local plugins directory:

```bash
git -C ~/.cursor/plugins/sources/miranda pull || git clone https://github.com/sandgardenhq/miranda.git ~/.cursor/plugins/sources/miranda
mkdir -p ~/.cursor/plugins/local
ln -sf ~/.cursor/plugins/sources/miranda/plugins/miranda ~/.cursor/plugins/local/miranda
```

Open Cursor's Customize sidebar → Plugins and enable **miranda** if it isn't
already on. The first MCP call opens a one-time browser sign-in. Note:
Cursor's hooks are wired but currently report no usage data — Cursor's local
session storage doesn't carry reliable token counts yet.

Now ask your agent:

```text
Set up usage tracking in this repo
```

That invokes the `setting-up-usage-tracking` skill, which wires
`.miranda/USING-MIRANDA.md` into your project and mints this machine's
usage-collector credential.

If your org is on a Cursor Team or Enterprise plan, an admin can instead
import this repo once for everyone: Dashboard → Settings → Plugins → Team
Marketplaces → Import → `sandgardenhq/miranda`.

## Migrating from the gloria marketplace

Token-usage tracking (the `enable_usage_tracking`/`tag_session_work_item`
setup flow, the collector hooks) previously shipped inside the `gloria`
plugin. A gloria install predating this extraction keeps working as-is until
it's updated — the two plugins must not both run the collector at once, so
update gloria before or alongside installing this one:

1. Update your `gloria` plugin install — after the extraction it no longer
   bundles the collector or its hooks.
2. Add this marketplace and install `miranda` using the
   [Install](#install) commands for your agent.
3. Run `setting-up-usage-tracking` (or ask your agent to "set up usage
   tracking") to re-wire the credential — the same `config.json` both plugins
   share (in `$XDG_CONFIG_HOME/sandgarden`, defaulting to
   `~/.config/sandgarden`), so if it already exists nothing needs re-minting.
   A machine set up before that directory was renamed still has its
   credential in `~/.gloria/`; the collector copies it across automatically
   on its next run, so that counts as already-enabled too.

## Updating

| Agent        | Command                                                     |
| ------------ | ----------------------------------------------------------- |
| Claude Code  | `/plugin marketplace update miranda` then `/reload-plugins` |
| OpenAI Codex | `codex plugin marketplace upgrade miranda` (restart Codex)  |
| OpenCode     | `rm -rf ~/.cache/opencode/node_modules/miranda` and restart |
| Cursor       | `git -C ~/.cursor/plugins/sources/miranda pull`             |

## Links

- Miranda — <https://miranda.co>
- gloria.dev — <https://gloria.dev>
- MCP server — <https://mcp.gloria.dev/miranda>

---

<p align="center"><sub>© Sandgarden, Inc. · gloria@sandgarden.com</sub></p>
