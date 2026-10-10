<h1 align="center">Miranda</h1>

<p align="center">
  <strong>This repo has moved to <a href="https://github.com/sandgardenhq/plugins">sandgardenhq/plugins</a>.</strong>
</p>

---

The `miranda` plugin now ships from the **`sandgarden`** marketplace at **[sandgardenhq/plugins](https://github.com/sandgardenhq/plugins)**, together with gloria, miranda, and doc-holiday. This repo is no longer updated and will be archived.

## Install

Run each command from inside the agent unless noted.

### Claude Code

```text
/plugin marketplace add sandgardenhq/plugins
/plugin install miranda@sandgarden
```

### OpenAI Codex

```bash
codex plugin marketplace add sandgardenhq/plugins   # in your shell
```

Then, inside Codex, run `/plugins`, install `miranda`, and start a new session. Finally, complete the one-time OAuth handshake for the plugin's MCP server:

```bash
codex mcp login miranda   # in your shell
```

### OpenCode

Add the plugin to your `opencode.json`, then restart OpenCode:

```json
{ "plugin": ["@sandgarden/miranda"] }
```

### Cursor

```bash
git -C ~/.cursor/plugins/sources/sandgarden pull || git clone https://github.com/sandgardenhq/plugins.git ~/.cursor/plugins/sources/sandgarden
mkdir -p ~/.cursor/plugins/local
rm -rf ~/.cursor/plugins/local/miranda
cp -R ~/.cursor/plugins/sources/sandgarden/plugins/miranda ~/.cursor/plugins/local/miranda
```

Copy rather than symlink: Cursor does not load a symlinked local plugin (see [cursor/plugins#35](https://github.com/cursor/plugins/issues/35)). Restart Cursor or run **Developer: Reload Window**.

## Already installed from this repo? Switch over

- **Claude Code:** remove the old `miranda` marketplace, then install from `sandgarden` as above:

  ```text
  /plugin marketplace remove miranda
  ```

- **OpenAI Codex:** remove the old `miranda` marketplace, then install from `sandgarden` as above:

  ```bash
  codex plugin marketplace remove miranda   # in your shell
  ```

- **OpenCode:** in `opencode.json`, replace `miranda@git+https://github.com/sandgardenhq/miranda.git` with `@sandgarden/miranda`, clear OpenCode's plugin cache, and restart OpenCode:

  ```bash
  rm -rf ~/.cache/opencode/node_modules
  ```

- **Cursor:** delete the old symlink or copy and the old clone, then follow the [Cursor install steps](#cursor):

  ```bash
  rm -rf ~/.cursor/plugins/local/miranda ~/.cursor/plugins/sources/miranda
  ```

## The usage collector

- **Standalone installer:** `curl -fsSL https://miranda.co/install.sh | sh` now serves the installer from `sandgardenhq/plugins`.
- **Releases:** collector binaries and installers are published at [sandgardenhq/plugins/releases](https://github.com/sandgardenhq/plugins/releases).

## Learn more

- Full install guide, for every agent and plugin: <https://github.com/sandgardenhq/plugins#readme>
- Miranda: <https://miranda.co>

<sub>Maintainers: `collector/manifest.json` in this repo is still updated automatically so older collectors keep self-updating. Don't delete it.</sub>

---

<p align="center"><sub>© Sandgarden, Inc. · gloria@sandgarden.com</sub></p>
