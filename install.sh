#!/bin/sh
# Miranda collector — standalone installer (#1229, epic #845 sub-project F).
#
#   curl -fsSL https://miranda.co/install.sh | sh
#
# The channel that needs no coding-agent plugin, no package manager and no
# administrator: it downloads the same compiled binary every other channel
# installs, verifies it against the SHA-256 checksums stamped below at publish
# time, puts it in ~/.local/bin, and registers the per-user service with
# `miranda-collector daemon install` (#1226). Then it stops — the daemon idles
# without config.json and prompts for sign-in itself (#1227), which is where
# every channel converges.
#
# POSIX `sh`, self-contained, and deliberately NOT the plugin stub
# (src/stub/stub.sh) even though it shares its download-and-verify shape. The
# two have opposite contracts:
#
#   stub.sh   runs inside an agent loop and exits 0 on EVERY failure — breaking
#             someone's coding session to report a download problem is worse
#             than collecting nothing for one turn.
#   install.sh  runs in a human's terminal, at their request, and FAILS LOUDLY —
#             an installer that installs nothing and says nothing is the worst
#             of the three possible outcomes.
#
# It never prompts. `curl … | sh` leaves stdin pointing at the pipe, so a
# `read` here would consume the script's own remaining bytes; the knobs are
# environment variables instead:
#
#   MIRANDA_INSTALL_DIR   where to put the binary (default ~/.local/bin)
#   MIRANDA_SKIP_SERVICE  set to anything to install the binary only — what an
#                         image build wants, where there is no login session
#                         for a per-user service to attach to
#
# Windows is not served here: its channels are the MSI and winget, which
# register the machine-wide scheduled task a per-user installer cannot.

set -u

# Stamped by .github/workflows/publish-miranda-marketplace.yml at publish time
# (same sed + grep-verify mechanism as stub.sh, and for the same reason: the
# checksums are the trust anchor, so a substituted release asset fails closed).
# Each placeholder appears exactly once so that verification cannot pass on a
# half-stamped file.
BUILD_VERSION="d852b0a62e33"
RELEASE_TAG="collector-d852b0a62e33"
RELEASE_REPO="sandgardenhq/miranda"
ASSET_PREFIX="miranda-collector"
CHECKSUM_DARWIN_ARM64="2cb4fd4897aba61db7fe2b446ee9ffbfe734fd79381be90af4372983ffca1c47"
CHECKSUM_DARWIN_X64="3b182a46040fc3cdb72c45e8b853a0f74da25cf269d489791fa8f3b32e6adc94"
CHECKSUM_LINUX_X64="f04e9c4fc09111afd43d1bc7ed0f7f11049b4cc8796da968bfed927717014f53"
CHECKSUM_LINUX_ARM64="a33c5e9236aa5d08878d774c3afeaa341a884662464a445a7b044b8b841bf335"

CURL_MAX_SECONDS=600
BINARY_NAME="miranda-collector"

# The partial download in flight, if any. Cleared once it has been renamed
# into place, so the traps below have nothing left to remove.
TMP_DOWNLOAD=""

clean_tmp() {
  # Both halves: the partial binary AND the file curl's own diagnosis is
  # captured into, which sits beside it and would otherwise outlive it.
  [ -n "$TMP_DOWNLOAD" ] && rm -f "$TMP_DOWNLOAD" "$TMP_DOWNLOAD.stderr" 2>/dev/null
  TMP_DOWNLOAD=""
  return 0
}

# Ctrl-C during the ~50 MB download is the ordinary way this ends. Without
# these, every interrupted attempt leaves a miranda-collector.download-<pid>
# in the install directory for ever — and nothing ever cleans them up, because
# a successful run only removes its own. Each signal trap exits explicitly:
# POSIX resumes the script after a trap action otherwise.
trap 'clean_tmp' EXIT
trap 'clean_tmp; exit 130' INT
trap 'clean_tmp; exit 143' TERM
trap 'clean_tmp; exit 129' HUP

fail() {
  printf 'miranda-collector install: %s\n' "$1" >&2
  exit 1
}

note() {
  printf '%s\n' "$1"
}

# Map uname's platform/arch to the release asset, or fail naming the channel
# that does serve this platform. Sets ASSET_KEY and ASSET_NAME.
resolve_asset() {
  ra_sys="$(uname -s 2>/dev/null || printf 'unknown')"
  ra_machine="$(uname -m 2>/dev/null || printf 'unknown')"
  case "$ra_sys" in
    Darwin) ra_platform=darwin ;;
    Linux) ra_platform=linux ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      fail "Windows is installed with the MSI or with winget (winget install ${ASSET_PREFIX}), not with this script"
      ;;
    *) ra_platform="$ra_sys" ;;
  esac
  case "$ra_machine" in
    arm64 | aarch64) ra_arch=arm64 ;;
    x86_64 | amd64) ra_arch=x64 ;;
    *) ra_arch="$ra_machine" ;;
  esac
  ASSET_KEY="$ra_platform-$ra_arch"
  case "$ASSET_KEY" in
    darwin-arm64 | darwin-x64 | linux-x64 | linux-arm64) ;;
    *) fail "no Miranda collector build for $ASSET_KEY" ;;
  esac
  ASSET_NAME="$ASSET_PREFIX-$ASSET_KEY"
}

# The stamped checksum for an asset key. One variable per platform, as in
# stub.sh: it is also what keeps each placeholder appearing exactly once for
# the publish workflow's sed (which has no /g).
checksum_for() {
  case "$1" in
    darwin-arm64) printf '%s' "$CHECKSUM_DARWIN_ARM64" ;;
    darwin-x64) printf '%s' "$CHECKSUM_DARWIN_X64" ;;
    linux-x64) printf '%s' "$CHECKSUM_LINUX_X64" ;;
    linux-arm64) printf '%s' "$CHECKSUM_LINUX_ARM64" ;;
  esac
}

# Lowercase hex SHA-256, using whichever tool this host has.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    # `$1`, NOT `$NF`: shasum prints "<digest>  <file>", so the last field is
    # the FILE NAME. Stock macOS has shasum and no sha256sum, which makes this
    # the default path on the platform this installer mainly exists for — a
    # `$NF` here refuses every macOS install with a checksum mismatch.
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  else
    return 1
  fi
}

# Is $1 one of the PATH entries? Exact segment match — a substring test would
# call ~/.local/binx a hit.
on_path() {
  op_target="$1"
  op_rest="${PATH-}:"
  while [ -n "$op_rest" ]; do
    op_entry="${op_rest%%:*}"
    op_rest="${op_rest#*:}"
    [ "$op_entry" = "$op_target" ] && return 0
    [ "$op_rest" = "$op_entry" ] && break
  done
  return 1
}

main() {
  # Dev tree: the publish workflow never stamped this copy.
  case "$BUILD_VERSION" in
    __*) fail "this copy of install.sh is unstamped (placeholder values); download it from https://miranda.co/install.sh" ;;
  esac

  command -v curl >/dev/null 2>&1 || fail "curl is required"
  resolve_asset

  install_dir="${MIRANDA_INSTALL_DIR:-$HOME/.local/bin}"
  target="$install_dir/$BINARY_NAME"
  mkdir -p "$install_dir" 2>/dev/null || fail "cannot create $install_dir"

  tmp="$target.download-$$"
  TMP_DOWNLOAD="$tmp"
  curl_errors="$tmp.stderr"
  url="https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"
  note "Downloading $ASSET_NAME ($BUILD_VERSION)…"

  # --proto/--proto-redir '=https' refuse a plain-http hop outright rather than
  # letting one be detected after the bytes have already moved; --write-out
  # reports the URL the transfer actually landed on, for the allowlist below.
  effective="$(
    curl --fail --location --silent --show-error \
      --proto '=https' --proto-redir '=https' \
      --max-redirs 5 --max-time "$CURL_MAX_SECONDS" \
      --write-out '%{url_effective}' \
      --output "$tmp" "$url" 2>"$curl_errors"
  )"
  curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    # curl already said what went wrong — a 404 for an asset that was never
    # uploaded, a proxy refusing CONNECT, an expired CA bundle. Throwing that
    # away and guessing "check your network" sends whoever ran this to look in
    # the wrong place. `--show-error` above is what makes it say anything.
    curl_message="$(tr '\n' ' ' <"$curl_errors" 2>/dev/null)"
    rm -f "$curl_errors" 2>/dev/null || :
    fail "download failed (curl exit $curl_status): ${curl_message:-no further detail}
  URL: $url"
  fi
  rm -f "$curl_errors" 2>/dev/null || :

  # GitHub serves release assets from its own object hosts. Requiring a literal
  # "/" after the host is what makes github.com.evil.example fail to match.
  # Defense in depth on top of the checksum.
  case "$effective" in
    https://github.com/* | https://objects.githubusercontent.com/* | https://release-assets.githubusercontent.com/*) ;;
    *)
      rm -f "$tmp" 2>/dev/null || :
      fail "download resolved to disallowed URL $effective; refusing"
      ;;
  esac

  expected="$(checksum_for "$ASSET_KEY")"
  if ! actual="$(sha256_of "$tmp")"; then
    rm -f "$tmp" 2>/dev/null || :
    fail "no SHA-256 tool found (sha256sum, shasum, or openssl); refusing to install unverified bytes"
  fi
  if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    rm -f "$tmp" 2>/dev/null || :
    fail "checksum mismatch for $ASSET_NAME: expected $expected, got ${actual:-nothing}; refusing to install"
  fi

  chmod 755 "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || :
    fail "cannot make $ASSET_NAME executable"
  }
  # Atomic: nobody ever sees a partial binary at $target, and replacing a
  # running one is a rename rather than a write.
  mv -f "$tmp" "$target" 2>/dev/null || {
    fail "cannot install into $target"
  }
  TMP_DOWNLOAD="" # renamed, not left behind: nothing for the traps to remove
  note "Installed $target"

  if [ -n "${MIRANDA_SKIP_SERVICE-}" ]; then
    note "Skipping service registration (MIRANDA_SKIP_SERVICE is set)."
  elif "$target" daemon install; then
    :
  else
    # A machine with no service mechanism at all (a container, a locked-down
    # host) is not a failed install: the binary is in place, the hooks and
    # `daemon ensure` still start a daemon, and `daemon install` has already
    # said what it could not do.
    note "Could not register a background service; the collector still runs from your coding agent."
  fi

  if ! on_path "$install_dir"; then
    note ""
    note "$install_dir is not on your PATH. Add it to your shell profile:"
    note "  export PATH=\"$install_dir:\$PATH\""
  fi

  note ""
  note "Next: connect this machine to your Miranda organization."
  note "  $BINARY_NAME setup"
  note "(The collector also prompts you the first time it runs without a connection.)"
}

main "$@"
