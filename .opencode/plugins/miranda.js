import { spawn } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// The bundled skills live at the repo root /skills, two levels up from this
// plugin file — in both the monorepo (dev) and the published package. Shared
// with the gloria and doc-holiday plugins: all three publish workflows stage
// the same canonical /skills sources to their own published root.
const skillsDir = path.resolve(__dirname, "../../skills")

// The collector download stub is shared with the Claude Code/Codex plugin,
// staged at the published repo's plugins/miranda/collector/stub.mjs (never
// committed under the monorepo's true root — see
// publish-miranda-marketplace.yml). In the monorepo checkout this path does
// not exist, so triggerCollectorSweep's existsSync guard silently no-ops
// during local dev.
const collectorStubPath = path.resolve(__dirname, "../../plugins/miranda/collector/stub.mjs")

/**
 * Mutate an OpenCode config object to wire up Miranda: register the bundled
 * skills directory and the scoped /miranda MCP endpoint (identity + cost
 * tools only — see packages/mcp/src/index.ts). Idempotent and
 * non-clobbering — a user-defined miranda MCP entry wins.
 */
export function applyMirandaConfig(config, dir = skillsDir) {
  config.skills = config.skills || {}
  config.skills.paths = config.skills.paths || []
  if (!config.skills.paths.includes(dir)) config.skills.paths.push(dir)
  config.mcp = config.mcp || {}
  config.mcp.miranda = config.mcp.miranda || {
    type: "remote",
    url: "https://mcp.gloria.dev/miranda",
    enabled: true,
  }
  return config
}

/**
 * Fire-and-forget trigger for the same usage-collector sweep Claude Code's
 * SessionStart hook runs (docs/plans/2026-07-08-coding-agent-token-tracking-design.md
 * §5): the collector re-scans all three local sources from their watermarks,
 * so any trigger source is safe to call repeatedly. This runs IN-PROCESS with
 * OpenCode (unlike Claude Code's spawned hook process), and a first run can
 * download a ~50 MB collector binary — so the child is detached and unref'd
 * rather than awaited, and every failure (missing stub, spawn error) is
 * swallowed: a collector bug must never block or slow an OpenCode session.
 */
export function triggerCollectorSweep(spawnImpl = spawn, stubPath = collectorStubPath) {
  try {
    if (!fs.existsSync(stubPath)) return
    const child = spawnImpl("node", [stubPath, "hook-session-start"], {
      detached: true,
      stdio: "ignore",
    })
    child.on("error", () => {})
    child.unref()
  } catch {
    // Must never block or crash the session.
  }
}

// OpenCode plugin entry. The `config` hook receives OpenCode's config
// singleton; mutations here are visible when skills and MCP servers are
// resolved later. Unlike the gloria plugin, there is no session.created
// version-nudge check — Miranda ships no version-nudge hook at all (mirrors
// the doc-holiday precedent: no dedicated plugin-version endpoint to poll).
// `spawnImpl` and `stubPath` exist for test injection only — production
// callers never pass them, so they default to the real child_process.spawn
// and the shared collector stub path.
export const miranda = async ({ spawnImpl = spawn, stubPath = collectorStubPath } = {}) => ({
  config: async (config) => {
    applyMirandaConfig(config)
  },
  "session.created": async () => {
    triggerCollectorSweep(spawnImpl, stubPath)
  },
  // Closest OpenCode analog to Claude Code's per-turn Stop hook: fires once
  // the agent loop finishes a turn and is waiting on the user again.
  "session.idle": async () => {
    triggerCollectorSweep(spawnImpl, stubPath)
  },
})

export default miranda
