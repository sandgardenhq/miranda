#!/usr/bin/env node
// gloria collector download stub
// (docs/plans/2026-07-10-collector-binary-distribution-design.md)
//
// This single self-contained file ships verbatim into the published plugin as
// plugins/gloria/collector/stub.mjs — it must import NOTHING beyond node
// builtins. The plugin hooks invoke it with node (the plugin's version-check
// hook already requires node, so this adds zero installs); it downloads the
// compiled collector binary for this platform once per build version from the
// published repo's GitHub Release, verifies it against the SHA-256 checksums
// stamped below at publish time, caches it under ~/.gloria/bin/, and then
// execs it with argv + stdin passed through, mirroring its exit code.
//
// Contract (it runs inside the agent loop, like the hooks it fronts):
// - ANY failure — offline, GitHub down, unsupported platform, checksum
//   mismatch, old node — logs ONE line to ~/.gloria/collector.log and exits 0.
//   The next hook fire retries. It must never break an agent session.
// - Checksum mismatch NEVER executes the downloaded bytes: the stamped
//   checksums are the trust anchor (a substituted release asset fails closed).
// - GLORIA_COLLECTOR_BIN=<path> bypasses download entirely (local builds,
//   air-gapped installs, corp mirrors).
import { spawn } from "node:child_process"
import crypto from "node:crypto"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"

// Stamped by .github/workflows/publish-marketplace.yml (or, for another
// marketplace's own copy of this shared source, its own publish workflow —
// e.g. publish-miranda-marketplace.yml) at publish time — the source tree
// always carries the __PLACEHOLDER__ values (same mechanism as
// check-version.mjs's INSTALLED_VERSION). Each placeholder appears exactly
// once so the workflow's sed + grep verification can't miss.
//
// RELEASE_REPO and ASSET_PREFIX exist because this ONE stub.mjs source ships
// into multiple marketplaces' plugins (gloria, miranda, …), each releasing
// its own compiled collector binaries on its OWN repo's GitHub Releases —
// GitHub Releases are per-repo, so nothing is shared across them. Every
// marketplace's workflow stamps its own repo ("sandgardenhq/gloria" /
// "sandgardenhq/miranda") and asset-name prefix ("gloria-collector" /
// "miranda-collector") into its copy, so two plugins installed on the same
// machine cache and download distinctly-named binaries under the same
// shared ~/.gloria/bin/ directory without colliding.
export const BUILD_VERSION = "286e58efe2dd"
export const RELEASE_TAG = "collector-286e58efe2dd"
export const RELEASE_REPO = "sandgardenhq/miranda"
export const ASSET_PREFIX = "miranda-collector"
export const CHECKSUMS = {
  "darwin-arm64": "40ef8e698fc0ac537040f71730478b605c78469fac2261227030045b16c905f7",
  "darwin-x64": "482cd46117e78ad9100d424b2bdec53ddc1480339c8412d0ac5073c2e980ce8c",
  "linux-x64": "da1b8fdfd40a710c9f7ac99359a9eb3b6caeba593d19d4ec6b7e06217ea631e2",
  "linux-arm64": "19971cccd7c7a4035c6d3cc253a16d3b1158fc92ddf39b0dad928a72c1eb4043",
  "windows-x64": "66e250ae24b729e080bca2efc86f57bb831edf89fbc40daa8109cb2945937c56",
}

// node fetch follows redirects; GitHub release-asset downloads redirect to a
// GitHub-owned object host. Only these final hosts may serve the binary —
// defense-in-depth on top of the checksum. release-assets.githubusercontent.com
// is included alongside the design's objects.githubusercontent.com because
// GitHub serves release assets from both object hosts.
const ALLOWED_HOSTS = [
  "github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
]

/** A download lock older than this is a downloader that died mid-run: take it
 *  over (mirrors the collector's sweep-lock staleness cutoff). */
const LOCK_STALE_MS = 10 * 60 * 1000

const LOG_MAX_BYTES = 1024 * 1024

/** ~/.gloria, honoring GLORIA_HOME like the collector's state.ts (including
 *  "~/" expansion — hook configs and env files don't shell-expand). */
export function stubGloriaHome(env) {
  const fromEnv = env.GLORIA_HOME
  if (fromEnv === undefined) return path.join(os.homedir(), ".gloria")
  if (fromEnv.startsWith("~/")) return path.join(os.homedir(), fromEnv.slice(2))
  return fromEnv
}

/** Append one line to ~/.gloria/collector.log (rotating once past 1 MB, like
 *  the collector's own logger). Logging must never throw — exit 0 still holds. */
export function logStubError(env, message) {
  const line = `${new Date().toISOString()} collector-stub error: ${message}\n`
  try {
    const home = stubGloriaHome(env)
    fs.mkdirSync(home, { recursive: true })
    const logPath = path.join(home, "collector.log")
    try {
      if (fs.statSync(logPath).size > LOG_MAX_BYTES) {
        fs.renameSync(logPath, `${logPath}.1`) // rename overwrites the old .1
      }
    } catch {
      // No log yet or rotation failed — append regardless.
    }
    fs.appendFileSync(logPath, line)
  } catch {
    // Nowhere left to report to; the exit-0 contract still holds.
  }
}

/** Map platform/arch to the release asset. Returns null when unsupported.
 *  `assetPrefix` defaults to gloria's own prefix so this function's behavior
 *  is unchanged for any caller that doesn't pass one (matches the source
 *  tree's un-stamped default — run() always passes deps.assetPrefix, which
 *  a stamped copy sets explicitly). */
export function resolveAsset(platform, arch, assetPrefix = "gloria-collector") {
  const key =
    platform === "darwin" && arch === "arm64"
      ? "darwin-arm64"
      : platform === "darwin" && arch === "x64"
        ? "darwin-x64"
        : platform === "linux" && arch === "x64"
          ? "linux-x64"
          : platform === "linux" && arch === "arm64"
            ? "linux-arm64"
            : platform === "win32" && arch === "x64"
              ? "windows-x64"
              : null
  if (key === null) return null
  const ext = platform === "win32" ? ".exe" : ""
  return { key, ext, assetName: `${assetPrefix}-${key}${ext}` }
}

/**
 * Take the download lock with O_EXCL. A LIVE lock (younger than 10 min)
 * returns false — the loser exits 0 and lets the winner finish. A stale lock
 * is taken over by atomic rename (exactly one contender wins; an rm-based
 * takeover would let a loser delete the winner's fresh lock) — mirrors the
 * collector's acquireSweepLock.
 */
function acquireDownloadLock(lockPath, nowMs) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = fs.openSync(lockPath, "wx") // O_EXCL: fails if it exists
      fs.writeSync(fd, String(process.pid))
      fs.closeSync(fd)
      return true
    } catch (error) {
      if (error.code !== "EEXIST") throw error
      let mtimeMs
      try {
        mtimeMs = fs.statSync(lockPath).mtimeMs
      } catch {
        continue // the holder just released it — retry the O_EXCL create
      }
      if (nowMs - mtimeMs < LOCK_STALE_MS) {
        return false // a live download owns it
      }
      const takeoverPath = `${lockPath}.takeover-${crypto.randomUUID()}`
      try {
        fs.renameSync(lockPath, takeoverPath)
      } catch {
        return false // another contender won the takeover rename first
      }
      fs.rmSync(takeoverPath, { force: true })
      // Won the takeover — loop around and retry the O_EXCL create.
    }
  }
  return false
}

/**
 * Download the asset to a temp file, verify its SHA-256 against the stamped
 * checksum, then atomically rename into place. Returns true when binPath is
 * ready to execute; false (after logging) on any failure — the temp file and
 * lock are always cleaned up, and unverified bytes are never left executable
 * at binPath.
 */
async function downloadBinary(binPath, asset, deps) {
  const binDir = path.dirname(binPath)
  fs.mkdirSync(binDir, { recursive: true })
  const lockPath = path.join(binDir, ".download.lock")
  if (!acquireDownloadLock(lockPath, deps.now())) {
    return false // a concurrent session is downloading — silently defer
  }
  const tempPath = `${binPath}.download-${crypto.randomUUID()}`
  try {
    const url = `https://github.com/${deps.releaseRepo}/releases/download/${deps.releaseTag}/${asset.assetName}`
    const response = await deps.fetchImpl(url)
    if (!response.ok) {
      logStubError(deps.env, `download of ${asset.assetName} failed: HTTP ${response.status}`)
      return false
    }
    const finalUrl = new URL(response.url)
    if (finalUrl.protocol !== "https:") {
      // An allowed host over plain http is still a downgrade — refuse.
      logStubError(deps.env, `download resolved to non-https URL ${response.url}; refusing`)
      return false
    }
    if (!ALLOWED_HOSTS.includes(finalUrl.hostname)) {
      logStubError(
        deps.env,
        `download redirected to disallowed host ${finalUrl.hostname}; refusing`,
      )
      return false
    }
    if (response.body === null || response.body === undefined) {
      logStubError(deps.env, `download of ${asset.assetName} returned no body`)
      return false
    }
    const hash = crypto.createHash("sha256")
    const fd = fs.openSync(tempPath, "wx")
    try {
      for await (const chunk of response.body) {
        const buffer = Buffer.from(chunk)
        hash.update(buffer)
        fs.writeSync(fd, buffer)
      }
    } finally {
      fs.closeSync(fd)
    }
    const actual = hash.digest("hex")
    const expected = deps.checksums[asset.key]
    if (actual !== expected) {
      logStubError(
        deps.env,
        `checksum mismatch for ${asset.assetName}: expected ${expected}, got ${actual}; refusing to execute`,
      )
      return false // finally deletes the temp file — never executed
    }
    fs.chmodSync(tempPath, 0o755)
    fs.renameSync(tempPath, binPath) // atomic: readers never see a partial file
    return true
  } catch (error) {
    logStubError(deps.env, `download of ${asset.assetName} failed: ${error?.message ?? error}`)
    return false
  } finally {
    fs.rmSync(tempPath, { force: true }) // no-op after a successful rename
    fs.rmSync(lockPath, { force: true })
  }
}

/** Spawn the collector binary with argv + stdin passed through; resolve its
 *  exit code. A spawn failure logs and resolves 0 (exit-0 contract). */
function execBinary(binPath, argv, deps) {
  return new Promise((resolve) => {
    const child = deps.spawnImpl(binPath, argv, { stdio: "inherit" })
    child.on("error", (error) => {
      logStubError(deps.env, `spawn of ${binPath} failed: ${error?.message ?? error}`)
      resolve(0)
    })
    child.on("close", (code) => resolve(code ?? 0))
  })
}

/** A *.download-<uuid> temp older than this is a download that was SIGKILLed
 *  mid-write (the finally cleanup never ran): safe to sweep — a live download
 *  finishes in well under an hour or its lock has long gone stale. */
const DOWNLOAD_TEMP_STALE_MS = 60 * 60 * 1000

/** Delete cached collector binaries beyond the 2 most recent (by mtime),
 *  never the one just run, plus any stranded *.download-* temp file older
 *  than an hour. Best-effort: pruning must not fail the hook. `assetPrefix`
 *  defaults to gloria's own prefix (matches resolveAsset's default) so a
 *  binary cached by a DIFFERENTLY-stamped copy sharing the same ~/.gloria/bin/
 *  directory (e.g. gloria's and Miranda's plugins both installed) is never
 *  touched by this run's pruning. */
export function pruneCache(binDir, keepPath, assetPrefix = "gloria-collector") {
  try {
    const entries = fs.readdirSync(binDir)
    for (const name of entries) {
      if (!name.includes(".download-")) continue
      const filePath = path.join(binDir, name)
      try {
        if (Date.now() - fs.statSync(filePath).mtimeMs > DOWNLOAD_TEMP_STALE_MS) {
          fs.rmSync(filePath, { force: true })
        }
      } catch {
        // Raced with its own downloader — leave it be.
      }
    }
    const cached = entries
      .filter((name) => name.startsWith(`${assetPrefix}-`) && !name.includes(".download-"))
      .map((name) => {
        const filePath = path.join(binDir, name)
        return { filePath, mtimeMs: fs.statSync(filePath).mtimeMs }
      })
      .sort((a, b) => b.mtimeMs - a.mtimeMs)
    for (const { filePath } of cached.slice(2)) {
      if (filePath !== keepPath) fs.rmSync(filePath, { force: true })
    }
  } catch {
    // Best-effort only.
  }
}

export function defaultDeps() {
  return {
    env: process.env,
    platform: process.platform,
    arch: process.arch,
    nodeMajor: Number(process.versions.node.split(".")[0]),
    buildVersion: BUILD_VERSION,
    releaseTag: RELEASE_TAG,
    releaseRepo: RELEASE_REPO,
    assetPrefix: ASSET_PREFIX,
    checksums: CHECKSUMS,
    fetchImpl: globalThis.fetch,
    spawnImpl: spawn,
    now: () => Date.now(),
  }
}

/** The whole stub: resolve → (override | cache | download+verify) → exec →
 *  prune. Returns the process exit code; every failure path returns 0. */
export async function run(argv, overrides = {}) {
  const deps = { ...defaultDeps(), ...overrides }
  try {
    if (deps.nodeMajor < 18) {
      // fetch stabilized in node 18 — older nodes can't download safely.
      logStubError(deps.env, `node ${deps.nodeMajor} is too old (need >= 18); skipping`)
      return 0
    }
    const override = deps.env.GLORIA_COLLECTOR_BIN
    if (override !== undefined && override !== "") {
      return await execBinary(override, argv, deps)
    }
    const asset = resolveAsset(deps.platform, deps.arch, deps.assetPrefix)
    if (asset === null) {
      logStubError(deps.env, `unsupported platform ${deps.platform}-${deps.arch}; skipping`)
      return 0
    }
    if (deps.buildVersion.startsWith("__")) {
      // Dev tree: the publish workflow never stamped this copy. Local dev
      // runs `bun src/cli.ts ...` or sets GLORIA_COLLECTOR_BIN instead.
      logStubError(
        deps.env,
        "stub is unstamped (dev checkout?); set GLORIA_COLLECTOR_BIN or install the published plugin",
      )
      return 0
    }
    const binDir = path.join(stubGloriaHome(deps.env), "bin")
    const binPath = path.join(binDir, `${deps.assetPrefix}-${deps.buildVersion}${asset.ext}`)
    if (!fs.existsSync(binPath)) {
      const downloaded = await downloadBinary(binPath, asset, deps)
      if (!downloaded) return 0 // logged inside (or a silent lock deferral)
    }
    const code = await execBinary(binPath, argv, deps)
    pruneCache(binDir, binPath, deps.assetPrefix)
    return code
  } catch (error) {
    logStubError(deps.env, `unexpected: ${error?.message ?? error}`)
    return 0
  }
}

/* v8 ignore start -- bin entrypoint; exercised by the spawned stamped-copy
   test, whose coverage a child process cannot report back. */
const invokedAsScript = (() => {
  if (process.argv[1] === undefined) return false
  try {
    // realpath both sides: node realpaths the ESM entry module, so a symlinked
    // path in argv[1] (e.g. macOS /var/folders -> /private/var/folders) would
    // otherwise never match import.meta.url.
    return import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href
  } catch {
    return false
  }
})()
if (invokedAsScript) {
  process.exit(await run(process.argv.slice(2)))
}
/* v8 ignore stop */
