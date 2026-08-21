#!/bin/sh
# gloria collector download stub
# (docs/plans/2026-08-21-collector-shell-bootstrap-design.md, superseding the
#  node stub of docs/plans/2026-07-10-collector-binary-distribution-design.md)
#
# This single self-contained file ships verbatim into the published plugin as
# plugins/<name>/collector/stub.sh. It is POSIX `sh` on purpose: every plugin
# hook command is ALREADY a shell-form string that Claude Code evaluates with
# `sh -c` on macOS/Linux and Git Bash on Windows, so `sh` is not a new
# prerequisite — it is what runs the hook line today. The previous stub was
# node, which made a JS runtime a hard host requirement and silently disabled
# usage tracking on machines without one (#761).
#
# It downloads the compiled collector binary for this platform once per build
# version from the published repo's GitHub Release, verifies it against the
# SHA-256 checksums stamped below at publish time, caches it under
# ~/.gloria/bin/, and runs it with argv + stdin passed through, mirroring its
# exit code.
#
# Contract (it runs inside the agent loop, like the hooks it fronts):
# - ANY failure — offline, GitHub down, unsupported platform, checksum
#   mismatch, no curl, no hashing tool — logs ONE line to
#   ~/.gloria/collector.log and exits 0. The next hook fire retries. It must
#   never break an agent session.
# - Checksum mismatch NEVER executes the downloaded bytes: the stamped
#   checksums are the trust anchor (a substituted release asset fails closed),
#   and unverified bytes are deleted rather than renamed into the cache.
# - GLORIA_COLLECTOR_BIN=<path> bypasses download entirely (local builds,
#   air-gapped installs, corp mirrors).
#
# Host tools: sh, curl, and one of sha256sum / shasum / openssl / certutil,
# plus the usual coreutils. There is deliberately no wget fallback: wget cannot
# report the effective final URL, so a wget path would silently drop the
# final-host allowlist below.

# Stamped by .github/workflows/publish-marketplace.yml (or, for another
# marketplace's own copy of this shared source, its own publish workflow —
# e.g. publish-miranda-marketplace.yml) at publish time — the source tree
# always carries the placeholder values (same mechanism as check-version.mjs's
# INSTALLED_VERSION). Each placeholder appears exactly once so the workflow's
# sed + grep verification can't miss.
#
# RELEASE_REPO and ASSET_PREFIX exist because this ONE stub source ships into
# multiple marketplaces' plugins (gloria, miranda, …), each releasing its own
# compiled collector binaries on its OWN repo's GitHub Releases — GitHub
# Releases are per-repo, so nothing is shared across them. Every marketplace's
# workflow stamps its own repo ("sandgardenhq/gloria" / "sandgardenhq/miranda")
# and asset-name prefix ("gloria-collector" / "miranda-collector") into its
# copy, so two plugins installed on the same machine cache and download
# distinctly-named binaries under the same shared ~/.gloria/bin/ directory
# without colliding.
BUILD_VERSION="299caecaf574"
RELEASE_TAG="collector-299caecaf574"
RELEASE_REPO="sandgardenhq/miranda"
ASSET_PREFIX="miranda-collector"
CHECKSUM_DARWIN_ARM64="4d960bb339d7301679120f491e47ff5be553c25721f7b264c75798a2837f0e1a"
CHECKSUM_DARWIN_X64="e0228df60dd507fa70dc8b880bf6ea7ac8e2b1d6742c1ee67b1db576a7c3503b"
CHECKSUM_LINUX_X64="89e234ee78c4cf17b13a276f73f6c5dc3e4bdcc3d99358f73ebf38357839af68"
CHECKSUM_LINUX_ARM64="1dc5f0a0e864a571b49268cbab0ec2c5ffc98ac13e2875bc64011012d86291e8"
CHECKSUM_WINDOWS_X64="330095f7e46864412c92d629b57d1f2274352c69674fb0c4e601ef2c0bc5c002"

# A download lock older than this is a downloader that died mid-run: take it
# over (mirrors the collector's sweep-lock staleness cutoff).
LOCK_STALE_MINUTES=10
# A *.download-* temp older than this is a download that was SIGKILLed
# mid-write (the cleanup never ran): safe to sweep — a live download finishes
# in well under an hour or its lock has long gone stale.
DOWNLOAD_TEMP_STALE_MINUTES=60
LOG_MAX_BYTES=1048576
CURL_MAX_SECONDS=600

# ~/.gloria, honoring GLORIA_HOME like the collector's state.ts (including
# "~/" expansion — hook configs and env files don't shell-expand).
gloria_home() {
  gh_value="${GLORIA_HOME-}"
  if [ -z "$gh_value" ]; then
    printf '%s' "$HOME/.gloria"
    return 0
  fi
  case "$gh_value" in
    "~/"*) printf '%s' "$HOME/${gh_value#\~/}" ;;
    *) printf '%s' "$gh_value" ;;
  esac
}

# Append one line to ~/.gloria/collector.log (rotating once past 1 MB, like
# the collector's own logger). Logging must never fail — exit 0 still holds.
log_error() {
  le_home="$(gloria_home)"
  mkdir -p "$le_home" 2>/dev/null || return 0
  le_log="$le_home/collector.log"
  if [ -f "$le_log" ]; then
    le_size="$(wc -c <"$le_log" 2>/dev/null | tr -d ' ')"
    case "$le_size" in
      '' | *[!0-9]*) le_size=0 ;;
    esac
    if [ "$le_size" -gt "$LOG_MAX_BYTES" ]; then
      mv -f "$le_log" "$le_log.1" 2>/dev/null || : # rename overwrites the old .1
    fi
  fi
  le_stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  printf '%s collector-stub error: %s\n' "$le_stamp" "$1" >>"$le_log" 2>/dev/null || :
  return 0
}

# Map uname's platform/arch to the release asset. Sets ASSET_KEY, ASSET_EXT and
# ASSET_NAME; returns 1 (leaving the pair in PLATFORM_LABEL) when unsupported.
# MINGW/MSYS/CYGWIN are how Git Bash — the shell Claude Code runs hooks in on
# Windows — reports itself.
resolve_asset() {
  ra_sys="$(uname -s 2>/dev/null || printf 'unknown')"
  ra_machine="$(uname -m 2>/dev/null || printf 'unknown')"
  case "$ra_sys" in
    Darwin) ra_platform=darwin ;;
    Linux) ra_platform=linux ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) ra_platform=windows ;;
    *) ra_platform="$ra_sys" ;;
  esac
  case "$ra_machine" in
    arm64 | aarch64) ra_arch=arm64 ;;
    x86_64 | amd64) ra_arch=x64 ;;
    *) ra_arch="$ra_machine" ;;
  esac
  PLATFORM_LABEL="$ra_platform-$ra_arch"
  ASSET_EXT=""
  case "$PLATFORM_LABEL" in
    darwin-arm64 | darwin-x64 | linux-x64 | linux-arm64) ASSET_KEY="$PLATFORM_LABEL" ;;
    windows-x64)
      ASSET_KEY="windows-x64"
      ASSET_EXT=".exe"
      ;;
    *) return 1 ;;
  esac
  ASSET_NAME="$ASSET_PREFIX-$ASSET_KEY$ASSET_EXT"
  return 0
}

# The stamped checksum for an asset key. POSIX sh has no associative arrays,
# and one variable per platform is also what keeps every checksum placeholder
# appearing exactly once for the publish workflow's sed (which has no /g, and
# whose grep verification would otherwise pass on a half-stamped file).
checksum_for() {
  case "$1" in
    darwin-arm64) printf '%s' "$CHECKSUM_DARWIN_ARM64" ;;
    darwin-x64) printf '%s' "$CHECKSUM_DARWIN_X64" ;;
    linux-x64) printf '%s' "$CHECKSUM_LINUX_X64" ;;
    linux-arm64) printf '%s' "$CHECKSUM_LINUX_ARM64" ;;
    windows-x64) printf '%s' "$CHECKSUM_WINDOWS_X64" ;;
  esac
}

# Lowercase hex SHA-256 of a file, using whichever tool this host has.
# certutil is the Windows built-in fallback for a Git Bash without coreutils.
# Returns 1 (and prints nothing) when the host has NO usable tool, which the
# caller reports differently from a tool that ran and failed.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  elif command -v certutil >/dev/null 2>&1; then
    certutil -hashfile "$1" SHA256 2>/dev/null | sed -n '2p' | tr -d ' \r' | tr 'A-F' 'a-f'
  else
    return 1
  fi
}

# Take the download lock. `mkdir` is the portable atomic create-or-fail. A LIVE
# lock (younger than LOCK_STALE_MINUTES) returns 1 — the loser exits 0 and lets
# the winner finish. A stale lock is taken over by rename, not by rm: exactly
# one contender can win a rename, whereas an rm-based takeover would let a
# loser delete the winner's freshly-created lock. Mirrors the collector's
# acquireSweepLock.
acquire_download_lock() {
  al_lock="$1"
  al_attempt=0
  while [ "$al_attempt" -lt 3 ]; do
    al_attempt=$((al_attempt + 1))
    if mkdir "$al_lock" 2>/dev/null; then
      return 0
    fi
    # `find -mmin` is absent only on exotic finds; when it can't tell, the lock
    # reads as live and this run defers — the next hook fire retries.
    if [ -z "$(find "$al_lock" -maxdepth 0 -mmin "+$LOCK_STALE_MINUTES" 2>/dev/null)" ]; then
      return 1
    fi
    al_takeover="$al_lock.takeover-$$-$al_attempt"
    if mv "$al_lock" "$al_takeover" 2>/dev/null; then
      rm -rf "$al_takeover" 2>/dev/null || :
      continue
    fi
    # The holder released it between our mkdir and our rename: retry the mkdir.
    [ -e "$al_lock" ] || continue
    return 1 # another contender won the takeover rename first
  done
  return 1
}

# Download the asset to a temp file, verify its SHA-256 against the stamped
# checksum, then atomically rename into place. Returns 0 when $1 is ready to
# execute; 1 (after logging, except on a silent lock deferral) otherwise. The
# temp file and the lock are always cleaned up, and unverified bytes are never
# left executable at the cache path.
download_binary() {
  db_bin="$1"
  db_dir="${db_bin%/*}"
  if ! mkdir -p "$db_dir" 2>/dev/null; then
    log_error "cannot create cache directory $db_dir"
    return 1
  fi
  db_lock="$db_dir/.download.lock"
  if ! acquire_download_lock "$db_lock"; then
    return 1 # a concurrent session is downloading — silently defer
  fi
  db_tmp="$db_bin.download-$$-$(date -u '+%s' 2>/dev/null || printf '0')"
  db_expected="$(checksum_for "$ASSET_KEY")"
  db_url="https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"
  db_status=1

  if ! command -v curl >/dev/null 2>&1; then
    log_error "curl not found; cannot download $ASSET_NAME"
  else
    # --proto/--proto-redir '=https' refuse a plain-http hop outright rather
    # than letting one be detected after the bytes have already moved;
    # --fail turns HTTP >= 400 into a non-zero exit; --write-out reports the
    # URL the transfer actually landed on, for the host allowlist below.
    db_effective="$(
      curl --fail --location --silent \
        --proto '=https' --proto-redir '=https' \
        --max-redirs 5 --max-time "$CURL_MAX_SECONDS" \
        --write-out '%{url_effective}' \
        --output "$db_tmp" "$db_url" 2>/dev/null
    )"
    db_curl_status=$?
    if [ "$db_curl_status" -ne 0 ]; then
      log_error "download of $ASSET_NAME failed: curl exit $db_curl_status"
    else
      # GitHub redirects release-asset downloads to a GitHub-owned object
      # host; it serves them from both objects. and release-assets.. Requiring
      # a literal "/" after the host is what makes github.com.evil.example
      # fail to match. Defense-in-depth on top of the checksum.
      case "$db_effective" in
        https://github.com/* | https://objects.githubusercontent.com/* | https://release-assets.githubusercontent.com/*)
          db_host_ok=yes
          ;;
        *) db_host_ok=no ;;
      esac
      if [ "$db_host_ok" = no ]; then
        log_error "download resolved to disallowed URL $db_effective; refusing"
      elif [ ! -s "$db_tmp" ]; then
        log_error "download of $ASSET_NAME returned no body"
      elif ! db_actual="$(sha256_of "$db_tmp")"; then
        log_error "no SHA-256 tool found (sha256sum, shasum, openssl, or certutil); refusing to execute $ASSET_NAME"
      elif [ -z "$db_actual" ]; then
        log_error "failed to compute the SHA-256 of $ASSET_NAME; refusing to execute"
      elif [ "$db_actual" != "$db_expected" ]; then
        log_error "checksum mismatch for $ASSET_NAME: expected $db_expected, got $db_actual; refusing to execute"
      elif ! chmod 755 "$db_tmp" 2>/dev/null; then
        log_error "cannot make $ASSET_NAME executable; refusing to install"
      elif ! mv -f "$db_tmp" "$db_bin" 2>/dev/null; then
        # atomic: readers never see a partial file
        log_error "cannot install $ASSET_NAME into $db_bin"
      else
        db_status=0
      fi
    fi
  fi

  rm -f "$db_tmp" 2>/dev/null || : # no-op after a successful rename
  rm -rf "$db_lock" 2>/dev/null || :
  return "$db_status"
}

# Run the collector binary with argv + stdin passed through and echo its exit
# code. Not `exec`, because the cache still has to be pruned afterwards.
# 126/127 are the shell's "couldn't execute that" codes — the equivalent of the
# node stub's spawn `error` event — so they log and become 0 rather than
# leaking out as a hook failure. The collector itself only ever exits 0 or 1.
run_binary() {
  rb_bin="$1"
  shift
  if [ ! -x "$rb_bin" ]; then
    log_error "spawn of $rb_bin failed: not executable"
    return 0
  fi
  "$rb_bin" "$@"
  rb_status=$?
  if [ "$rb_status" -eq 126 ] || [ "$rb_status" -eq 127 ]; then
    log_error "spawn of $rb_bin failed: exit $rb_status"
    return 0
  fi
  return "$rb_status"
}

# Delete cached collector binaries beyond the 2 most recent (by mtime), never
# the one just run, plus any stranded *.download-* temp file older than an
# hour. Best-effort: pruning must not fail the hook. Only files carrying THIS
# copy's stamped asset prefix are considered, so a binary cached by a
# differently-stamped copy sharing the same ~/.gloria/bin/ (e.g. gloria's and
# Miranda's plugins both installed) is never touched.
prune_cache() {
  pc_dir="$1"
  pc_keep="$2"
  [ -d "$pc_dir" ] || return 0
  find "$pc_dir" -maxdepth 1 -name '*.download-*' \
    -mmin "+$DOWNLOAD_TEMP_STALE_MINUTES" -exec rm -f {} + 2>/dev/null || :
  pc_kept=0
  # Cache entries are <prefix>-<hex> — no whitespace — so word splitting on
  # `ls -t` (newest first) is safe here, and it is the portable way to get
  # mtime order without a second sort tool.
  # shellcheck disable=SC2045
  for pc_name in $(ls -t "$pc_dir" 2>/dev/null); do
    case "$pc_name" in
      "$ASSET_PREFIX-"*) ;;
      *) continue ;;
    esac
    case "$pc_name" in
      *.download-*) continue ;;
    esac
    if [ "$pc_kept" -lt 2 ]; then
      pc_kept=$((pc_kept + 1))
      continue
    fi
    pc_path="$pc_dir/$pc_name"
    [ "$pc_path" = "$pc_keep" ] && continue
    rm -f "$pc_path" 2>/dev/null || :
  done
  return 0
}

# The whole stub: override | unstamped | resolve → (cache | download+verify) →
# run → prune. Every failure path exits 0.
main() {
  if [ -n "${GLORIA_COLLECTOR_BIN-}" ]; then
    if [ ! -x "$GLORIA_COLLECTOR_BIN" ]; then
      log_error "GLORIA_COLLECTOR_BIN=$GLORIA_COLLECTOR_BIN is not an executable file; skipping"
      exit 0
    fi
    # Nothing to prune on this path, so exec straight through: argv, stdin and
    # the exit code all pass to the override untouched.
    exec "$GLORIA_COLLECTOR_BIN" "$@"
  fi

  # Dev tree: the publish workflow never stamped this copy (the placeholders
  # are still in place). Local dev runs `bun src/cli.ts …` or sets
  # GLORIA_COLLECTOR_BIN instead.
  case "$BUILD_VERSION" in
    __*)
      log_error "stub is unstamped (dev checkout?); set GLORIA_COLLECTOR_BIN or install the published plugin"
      exit 0
      ;;
  esac

  if ! resolve_asset; then
    log_error "unsupported platform $PLATFORM_LABEL; skipping"
    exit 0
  fi

  m_bin_dir="$(gloria_home)/bin"
  m_bin="$m_bin_dir/$ASSET_PREFIX-$BUILD_VERSION$ASSET_EXT"
  if [ ! -f "$m_bin" ]; then
    download_binary "$m_bin" || exit 0 # logged inside (or a silent lock deferral)
  fi
  run_binary "$m_bin" "$@"
  m_status=$?
  prune_cache "$m_bin_dir" "$m_bin"
  exit "$m_status"
}

main "$@"
