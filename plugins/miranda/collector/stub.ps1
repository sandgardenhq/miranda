# gloria collector download stub — Windows / PowerShell
# (docs/plans/2026-09-21-windows-powershell-collector-bootstrap-design.md,
#  the Windows half of docs/plans/2026-08-21-collector-shell-bootstrap-design.md)
#
# This single self-contained file ships verbatim into the published plugin as
# plugins/<name>/collector/stub.ps1, beside its POSIX twin stub.sh. It exists
# because Claude Code evaluates a plugin hook command with Git Bash on Windows
# but Codex evaluates it with PowerShell, where the POSIX hook line fails
# before stub.sh is ever reached — silently collecting nothing, forever
# (#1307). The hooks' `commandWindows` override dispatches here instead.
#
# It is the same algorithm as stub.sh: download the compiled collector binary
# for this platform once per build version from the published repo's GitHub
# Release, verify it against the SHA-256 stamped below at publish time, cache
# it under the collector's state directory (`bin\`), and run it with argv +
# stdin passed through, mirroring its exit code. The cache path, the lock and
# the log are the SAME files stub.sh uses, so a machine running both Claude
# Code (Git Bash) and Codex (PowerShell) shares one cache, not two.
#
# Contract (it runs inside the agent loop, like the hooks it fronts):
# - ANY failure — offline, GitHub down, unsupported architecture, checksum
#   mismatch, no curl — logs ONE line to the state directory's collector.log
#   and exits 0. The next hook fire retries. It must never break a session.
# - Checksum mismatch NEVER executes the downloaded bytes: the stamped
#   checksum is the trust anchor (a substituted release asset fails closed),
#   and unverified bytes are deleted rather than renamed into the cache.
# - GLORIA_COLLECTOR_BIN=<path> bypasses download entirely (local builds,
#   air-gapped installs, corp mirrors).
#
# Host tools: Windows PowerShell 5.1 (present on every supported Windows host
# — this file stays inside the 5.1 syntax subset so `powershell -File` runs it
# as well as `pwsh` does) and curl.exe, shipped in System32 since Windows 10
# 1803 / Server 2019. curl rather than Invoke-WebRequest deliberately: it is
# the same transfer, with the same --proto/--max-redirs guarantees and the
# same `--write-out '%{url_effective}'` final-host check stub.sh relies on,
# instead of a redirect-reporting API that differs between PowerShell 5.1 and
# 7. Hashing uses Get-FileHash, which is built in. Note the `.exe`: in Windows
# PowerShell `curl` is an ALIAS for Invoke-WebRequest, so the bare name would
# not run curl at all.

# Stamped by .github/workflows/publish-marketplace.yml (or, for another
# marketplace's own copy of this shared source, its own publish workflow —
# e.g. publish-miranda-marketplace.yml) at publish time — the source tree
# always carries the placeholder values, exactly as stub.sh does. Each
# placeholder appears exactly once so the workflow's sed + grep verification
# can't miss. Only windows-x64 is carried: it is the only asset this file can
# ever resolve.
$BuildVersion = 'fd90b321920e'
$ReleaseTag = 'collector-fd90b321920e'
$ReleaseRepo = 'sandgardenhq/miranda'
$AssetPrefix = 'miranda-collector'
$ChecksumWindowsX64 = '53312621e731bfa80adb4f4645fe1b498403699bc4e7959f5c61f22bb9c54392'

# A download lock older than this is a downloader that died mid-run: take it
# over (mirrors the collector's sweep-lock staleness cutoff).
$LockStaleMinutes = 10
# A *.download-* temp older than this is a download that was killed mid-write.
$DownloadTempStaleMinutes = 60
$LogMaxBytes = 1048576
$CurlMaxSeconds = 600

# The pre-#783 state directory, kept only as a migration source.
$LegacyHomeDirName = '.gloria'

# Cmdlet failures become catchable terminating errors, so the top-level catch
# can honour "exit 0 on anything unforeseen"...
$ErrorActionPreference = 'Stop'
# ...but a NATIVE command's non-zero exit must NOT: PowerShell 7.4 turns that
# into a terminating error by default, and this stub mirrors the collector's
# exit code rather than failing on it. Assigning the variable is harmless on
# 5.1, which has no such behaviour.
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'

# The collector's exit code travels in a script variable, never as a function
# return value: a function's return value is its whole success stream, which
# would swallow the collector's own stdout (hook JSON the agent reads).
$script:CollectorExitCode = 0

function Get-HomeDirectory {
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  if ($env:HOME) { return $env:HOME }
  return ''
}

# Shells expand a leading "~" before we ever see it — hook configs and env
# files don't, so we have to.
function Expand-TildePath([string]$Value) {
  if ($Value -like '~/*' -or $Value -like '~\*') {
    return [System.IO.Path]::Combine((Get-HomeDirectory), $Value.Substring(2))
  }
  return $Value
}

# The explicit full-path override in effect, or '' when there is none.
# GLORIA_HOME is the deprecated alias of SANDGARDEN_HOME — it names one of the
# two products sharing this directory, which is exactly what #783 fixes, but a
# user who set it deliberately must not have their state silently relocated.
function Get-HomeOverride {
  if ($env:SANDGARDEN_HOME) { return (Expand-TildePath $env:SANDGARDEN_HOME) }
  if ($env:GLORIA_HOME) { return (Expand-TildePath $env:GLORIA_HOME) }
  return ''
}

# Mirrors stub.sh's collector_home(), and state.ts's collectorHome() behind it:
#   SANDGARDEN_HOME | GLORIA_HOME | $XDG_CONFIG_HOME/sandgarden | <profile>/.config/sandgarden
# [IO.Path]::Combine, not Join-Path, because Join-Path throws on an empty root
# and a host with no profile at all must still reach the log path.
function Get-CollectorHome {
  $override = Get-HomeOverride
  if ($override) { return $override }
  if ($env:XDG_CONFIG_HOME) {
    return [System.IO.Path]::Combine((Expand-TildePath $env:XDG_CONFIG_HOME), 'sandgarden')
  }
  return [System.IO.Path]::Combine((Get-HomeDirectory), '.config', 'sandgarden')
}

# Append one line to the state directory's collector.log (rotating once past
# 1 MB, like the collector's own logger, and using the same message prefix as
# stub.sh so one log stays readable). Logging must never fail — exit 0 still
# holds.
function Write-CollectorLog([string]$Message) {
  try {
    $stateDir = Get-CollectorHome
    if (-not (Test-Path -LiteralPath $stateDir)) {
      New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $logPath = [System.IO.Path]::Combine($stateDir, 'collector.log')
    if (Test-Path -LiteralPath $logPath) {
      if ((Get-Item -LiteralPath $logPath).Length -gt $LogMaxBytes) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force
      }
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Add-Content -LiteralPath $logPath -Value "$stamp collector-stub error: $Message"
  } catch {
    # Even the log is best-effort.
  }
}

# Map this host's architecture to the release asset. Returns $null when the
# pair is unsupported, leaving the label in $script:PlatformLabel.
# PROCESSOR_ARCHITEW6432 is what a 32-bit PowerShell on 64-bit Windows reports
# the real machine as; PROCESSOR_ARCHITECTURE would say x86.
function Resolve-Asset {
  $arch = $env:PROCESSOR_ARCHITEW6432
  if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
  if (-not $arch) { $arch = 'unknown' }
  $script:PlatformLabel = "windows-$($arch.ToLowerInvariant())"
  if ($arch.ToUpperInvariant() -eq 'AMD64' -or $arch.ToUpperInvariant() -eq 'X64') {
    $script:PlatformLabel = 'windows-x64'
    return "$AssetPrefix-windows-x64.exe"
  }
  # Windows ARM64 is deliberately unsupported, exactly as in stub.sh: no
  # windows-arm64 asset is built, and running the x64 build under emulation is
  # a release decision, not a bootstrap one.
  return $null
}

# GitHub redirects release-asset downloads to a GitHub-owned object host; it
# serves them from both objects. and release-assets.. Requiring a literal "/"
# after the host is what makes github.com.evil.example fail to match. Defense
# in depth on top of the checksum, and the same allowlist stub.sh applies.
function Test-AllowedDownloadUrl([string]$Url) {
  return ($Url -like 'https://github.com/*' -or
    $Url -like 'https://objects.githubusercontent.com/*' -or
    $Url -like 'https://release-assets.githubusercontent.com/*')
}

# Take the download lock. Creating a directory without -Force is the atomic
# create-or-fail. A LIVE lock (younger than $LockStaleMinutes) returns $false —
# the loser exits 0 and lets the winner finish. A stale lock is taken over by
# rename, not by delete: exactly one contender can win a rename, whereas a
# delete-based takeover would let a loser remove the winner's fresh lock.
# Mirrors stub.sh's acquire_download_lock and the collector's acquireSweepLock.
function Request-DownloadLock([string]$LockPath) {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      New-Item -ItemType Directory -Path $LockPath -ErrorAction Stop | Out-Null
      return $true
    } catch {
      # Held by someone: fall through and judge its age.
    }
    # -Force: the lock is a dot-prefixed name, which PowerShell treats as
    # hidden on non-Windows hosts (where this file's own tests run).
    $held = Get-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    # Released between our create and our read: retry the create.
    if ($null -eq $held) { continue }
    if ($held.LastWriteTime -gt (Get-Date).AddMinutes(-$LockStaleMinutes)) { return $false }
    $takeover = "$LockPath.takeover-$PID-$attempt"
    try {
      Move-Item -LiteralPath $LockPath -Destination $takeover -ErrorAction Stop
      Remove-Item -LiteralPath $takeover -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      return $false # another contender won the takeover rename first
    }
  }
  return $false
}

# Reuse the binary a pre-#783 install already cached under <profile>\.gloria\bin
# instead of re-downloading it (#783) — an offline machine has to keep working
# across the rename. Returns $true when $BinPath is ready to run.
#
# Only THIS copy's own stamped asset name is considered, so an entry cached by
# a differently-stamped stub sharing the legacy bin\ (gloria's and Miranda's
# plugins both installed) is left where its owner expects it. Copy rather than
# move, for the same reason. Skipped when the directory was pinned explicitly —
# that path was chosen deliberately.
function Copy-LegacyCachedBinary([string]$BinPath) {
  if (Get-HomeOverride) { return $false }
  $legacy = [System.IO.Path]::Combine(
    (Get-HomeDirectory), $LegacyHomeDirName, 'bin', [System.IO.Path]::GetFileName($BinPath))
  if (-not (Test-Path -LiteralPath $legacy -PathType Leaf)) { return $false }
  $temp = "$BinPath.migrate-$PID"
  try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $BinPath) -Force | Out-Null
    Copy-Item -LiteralPath $legacy -Destination $temp -Force
    # Atomic: no partial file is ever run.
    Move-Item -LiteralPath $temp -Destination $BinPath -Force
    return $true
  } catch {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    return $false
  }
}

# Download the asset to a temp file, verify its SHA-256 against the stamped
# checksum, then atomically rename it into place. Returns $true when $BinPath is
# ready to run; $false (after logging, except on a silent lock deferral)
# otherwise. The temp file and the lock are always cleaned up, and unverified
# bytes are never renamed into the cache.
function Save-CollectorBinary([string]$BinPath, [string]$AssetName) {
  $binDir = Split-Path -Parent $BinPath
  try {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  } catch {
    Write-CollectorLog "cannot create cache directory $binDir"
    return $false
  }
  $lockPath = [System.IO.Path]::Combine($binDir, '.download.lock')
  # A concurrent session is downloading — silently defer to it.
  if (-not (Request-DownloadLock $lockPath)) { return $false }

  $temp = "$BinPath.download-$PID-$(Get-Random)"
  $url = "https://github.com/$ReleaseRepo/releases/download/$ReleaseTag/$AssetName"
  $installed = $false
  try {
    # curl.exe, not the bare name: in Windows PowerShell `curl` is an alias for
    # Invoke-WebRequest. --proto/--proto-redir '=https' refuse a plain-http hop
    # outright rather than letting one be detected after the bytes have already
    # moved; --fail turns HTTP >= 400 into a non-zero exit; --write-out reports
    # the URL the transfer actually landed on, for the host check below.
    $curl = Get-Command 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
      Write-CollectorLog "curl.exe not found; cannot download $AssetName"
    } else {
      $effective = & curl.exe --fail --location --silent `
        --proto '=https' --proto-redir '=https' `
        --max-redirs 5 --max-time $CurlMaxSeconds `
        --write-out '%{url_effective}' `
        --output $temp $url
      $curlStatus = $LASTEXITCODE
      $effectiveUrl = ($effective -join '').Trim()
      $downloaded = Get-Item -LiteralPath $temp -ErrorAction SilentlyContinue
      if ($curlStatus -ne 0) {
        Write-CollectorLog "download of $AssetName failed: curl exit $curlStatus"
      } elseif (-not (Test-AllowedDownloadUrl $effectiveUrl)) {
        Write-CollectorLog "download resolved to disallowed URL $effectiveUrl; refusing"
      } elseif ($null -eq $downloaded -or $downloaded.Length -eq 0) {
        Write-CollectorLog "download of $AssetName returned no body"
      } else {
        $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $ChecksumWindowsX64) {
          Write-CollectorLog "checksum mismatch for ${AssetName}: expected $ChecksumWindowsX64, got $actual; refusing to execute"
        } else {
          # Atomic: readers never see a partial file.
          Move-Item -LiteralPath $temp -Destination $BinPath -Force
          $installed = $true
        }
      }
    }
  } catch {
    Write-CollectorLog "download of $AssetName failed: $($_.Exception.Message)"
  } finally {
    # A no-op after a successful rename.
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue
  }
  return $installed
}

# Delete cached collector binaries beyond the 2 most recent (by last-write
# time), never the one just run, plus any stranded temp older than an hour.
# Best-effort: pruning must not fail the hook. Only files carrying THIS copy's
# stamped asset prefix are considered, so a binary cached by a
# differently-stamped copy sharing the same bin\ is never touched.
function Remove-StaleCacheEntries([string]$BinDir, [string]$KeepPath) {
  if (-not (Test-Path -LiteralPath $BinDir)) { return }
  try {
    $tempCutoff = (Get-Date).AddMinutes(-$DownloadTempStaleMinutes)
    $entries = @(Get-ChildItem -LiteralPath $BinDir -File -Force -ErrorAction SilentlyContinue)
    foreach ($entry in $entries) {
      $isTemp = ($entry.Name -like '*.download-*' -or $entry.Name -like '*.migrate-*')
      if ($isTemp -and $entry.LastWriteTime -lt $tempCutoff) {
        Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue
      }
    }
    $kept = 0
    $cached = @($entries | Where-Object {
        $_.Name -like "$AssetPrefix-*" -and
        $_.Name -notlike '*.download-*' -and
        $_.Name -notlike '*.migrate-*'
      } | Sort-Object LastWriteTime -Descending)
    foreach ($entry in $cached) {
      if ($kept -lt 2) {
        $kept++
        continue
      }
      if ($entry.FullName -eq $KeepPath) { continue }
      Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue
    }
  } catch {
    # Pruning is housekeeping; a failure here must not reach the hook.
  }
}

# Run the collector binary with argv + stdin passed through, recording its exit
# code in $script:CollectorExitCode. Native stdout/stderr are left alone — the
# agent reads them.
function Invoke-CollectorBinary([string]$BinPath, [string[]]$Arguments) {
  $script:CollectorExitCode = 0
  if (-not (Test-Path -LiteralPath $BinPath -PathType Leaf)) {
    Write-CollectorLog "spawn of $BinPath failed: not a file"
    return
  }
  try {
    & $BinPath @Arguments
    if ($null -ne $LASTEXITCODE) { $script:CollectorExitCode = $LASTEXITCODE }
  } catch {
    # The PowerShell equivalent of the POSIX 126/127 "couldn't execute that":
    # log it and let the hook succeed anyway.
    Write-CollectorLog "spawn of $BinPath failed: $($_.Exception.Message)"
    $script:CollectorExitCode = 0
  }
}

# The whole stub: override | unstamped | resolve -> cache -> run.
# Every failure path leaves $script:CollectorExitCode at 0.
function Invoke-Main([string[]]$Arguments) {
  if ($env:GLORIA_COLLECTOR_BIN) {
    if (-not (Test-Path -LiteralPath $env:GLORIA_COLLECTOR_BIN -PathType Leaf)) {
      Write-CollectorLog "GLORIA_COLLECTOR_BIN=$($env:GLORIA_COLLECTOR_BIN) is not an executable file; skipping"
      return
    }
    Invoke-CollectorBinary $env:GLORIA_COLLECTOR_BIN $Arguments
    return
  }

  # Dev tree: the publish workflow never stamped this copy (the placeholders
  # are still in place). Local dev runs `bun src/cli.ts ...` or sets
  # GLORIA_COLLECTOR_BIN instead.
  if ($BuildVersion -like '__*') {
    Write-CollectorLog 'stub is unstamped (dev checkout?); set GLORIA_COLLECTOR_BIN or install the published plugin'
    return
  }

  $assetName = Resolve-Asset
  if (-not $assetName) {
    Write-CollectorLog "unsupported platform $script:PlatformLabel; skipping"
    return
  }

  $binDir = [System.IO.Path]::Combine((Get-CollectorHome), 'bin')
  $binPath = [System.IO.Path]::Combine($binDir, "$AssetPrefix-$BuildVersion.exe")
  if (-not (Test-Path -LiteralPath $binPath -PathType Leaf)) {
    if (-not (Copy-LegacyCachedBinary $binPath)) {
      # Logged inside, or a silent lock deferral.
      if (-not (Save-CollectorBinary $binPath $assetName)) { return }
    }
  }

  Invoke-CollectorBinary $binPath $Arguments
  Remove-StaleCacheEntries $binDir $binPath
}

try {
  Invoke-Main $args
} catch {
  Write-CollectorLog "unexpected failure: $($_.Exception.Message)"
  $script:CollectorExitCode = 0
}
exit $script:CollectorExitCode
