#!/bin/sh
# tmh-install: installer for the thatsmyhuman CLI suite (tmh, tmh-broker, mcp-agent).
#
# THIS SCRIPT IS A TRUST ROOT. It is delivered over portal TLS and via the public
# mirror at https://github.com/thatsmyhuman/tmh-install. It downloads proprietary
# binaries, then verifies them with a SHA256 checksum (always) and a minisign
# signature (when minisign is available / required). Read the heavily-commented
# checksum, signature, and symlink-flip sections before changing them.
#
# The script is written in STRICT POSIX sh (dash-compatible) and is structured so
# that every unit of work is a function, with the sole top-level statement being
# `main "$@"` on the LAST line. If a `curl | sh` delivery is truncated mid-flight,
# the shell parses the partial function definitions but never reaches `main`, so
# NOTHING executes. This is the "main-at-end truncation safety" property — do not
# add executable top-level statements above `main "$@"`.
#
# No telemetry, no phone-home. This is deliberate. Do not add any.
#
# License: the installer wrapper is MIT. The downloaded binaries are proprietary.

set -eu

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# The one stable public URL pre-apex. Every error message points here.
README_URL="https://github.com/thatsmyhuman/tmh-install#readme"

# Default download origin (API-free "latest" redirect + pinned-version path).
GH_REPO="thatsmyhuman/tmh-install"

# Where an operator finds a valid value for TMH_INSTALL_VERSION.
RELEASES_URL="https://github.com/thatsmyhuman/tmh-install/releases"

# Minimum supported glibc. Debian 12+, Ubuntu 22.04+, RHEL 9+.
MIN_GLIBC_MAJOR="2"
MIN_GLIBC_MINOR="35"

# Pinned minisign public key. The operator REPLACES this placeholder with the
# real release-signing pubkey at release time. The same key is additionally
# published at {portal}/minisign.pub for out-of-band verification.
# minisign public keys start with "RW".
MINISIGN_PUBLIC_KEY="RWRuUhkMimvWU+Xp3zPJLvzFwmCuLenHg4WB5xNtNMqGF4+LsiK7Upgc"

# Release metadata file, written inside every release dir this script creates.
# It is what makes a re-run HONEST: without it the installer could only ask "is
# there a directory with the right name", which is why an unpinned re-run used
# to discard a freshly verified download (issue #336).
META_FILE=".tmh-install"

# Markers delimiting the managed PATH block in the user's shell rc files. These
# are the idempotency key (an existing block is REPLACED, never duplicated) and
# exactly what `--uninstall` strips back out (issue #337).
PATH_BLOCK_BEGIN="# >>> tmh installer (managed) >>>"
PATH_BLOCK_END="# <<< tmh installer (managed) <<<"

# ---------------------------------------------------------------------------
# Mutable state.
#
# The file's only mutable globals. POSIX sh has no way to return a second value
# from a function, and stdout is reserved for the machine-contract line, so the
# handful of values that must cross function boundaries live here. These are
# top-level ASSIGNMENTS, not top-level actions: the main-at-end truncation-safety
# property forbids executable work above `main`, not variable definitions.
# ---------------------------------------------------------------------------

# Set to 1 by verify_signature ONLY on the branch that actually verified a
# signature against the pinned key. Everything downstream that trusts the
# tarball's own contents (the version probe) is gated on this.
SIGNATURE_VERIFIED=0

# Resolved release label (= the directory name under <prefix>/releases and the
# target of <prefix>/current), the probed binary version, and the tarball's
# short digest. All three are reported on the machine-contract line.
INSTALLED_VERSION=""
BINARY_VERSION=""
RELEASE_DIGEST=""

# 1 when a managed PATH block was actually written to at least one shell rc.
PATH_PERSISTED=0

# Paths the EXIT/INT/TERM trap has to clean up. Named individually rather than
# accumulated in one word-split list so a path containing whitespace cannot
# turn cleanup into `rm -rf` on something else.
CLEANUP_STAGING=""
CLEANUP_WORKDIR=""
CLEANUP_LOCKDIR=""

# ---------------------------------------------------------------------------
# Output helpers. Human output goes to STDERR; the machine contract line is the
# ONLY thing written to STDOUT (see emit_ok). Agents parse stdout's last line.
# ---------------------------------------------------------------------------

log() {
	# Informational line to stderr.
	printf '%s\n' "$*" >&2
}

warn() {
	printf 'tmh-install: WARN: %s\n' "$*" >&2
}

# err prints a specific error plus the docs pointer, then exits non-zero.
# Every failure path routes through here so every error carries a docs pointer.
err() {
	printf 'tmh-install: ERROR: %s\n' "$*" >&2
	printf 'tmh-install: docs: %s\n' "$README_URL" >&2
	exit 1
}

# cleanup runs from the EXIT / INT / TERM traps installed by main. Before it
# existed, the download workdir leaked on every error path (the unconditional
# `rm -rf` sat at the END of main, reachable only on success) and the unpack
# staging dir leaked on the no-op re-run path, which is now taken often.
cleanup() {
	if [ -n "$CLEANUP_STAGING" ]; then
		rm -rf "$CLEANUP_STAGING"
		CLEANUP_STAGING=""
	fi
	if [ -n "$CLEANUP_WORKDIR" ]; then
		rm -rf "$CLEANUP_WORKDIR"
		CLEANUP_WORKDIR=""
	fi
	if [ -n "$CLEANUP_LOCKDIR" ]; then
		rmdir "$CLEANUP_LOCKDIR" 2>/dev/null || true
		CLEANUP_LOCKDIR=""
	fi
	return 0
}

# ensure_dir creates directory $1 and forces its mode to $2.
#
# `mkdir -p` alone is wrong here for two independent reasons, both observed in
# the field (issue #333):
#
#   1. mkdir applies the caller's UMASK, so on a umask-002 host the default
#      user-mode prefix $HOME/.tmh is born 0775 — group-writable.
#   2. mkdir -p silently no-ops on a directory that already exists, so a prefix
#      an earlier install created wrong is never healed by re-running.
#
# That matters because tmh's own guard (untrustedComponent in cmd/tmh/setup.go)
# walks EVERY ancestor of ~/.tmh/hsm.env and refuses any non-sticky component
# with group- or other-write set. A group-writable prefix therefore makes
# `tmh enroll` fail on a machine this installer just reported as OK — and the
# operator has no way to connect the refusal back to us. `tmh init-hsm` already
# takes the same care with the env-FILE (0600, re-tightened on re-run); this is
# the directory half of that contract.
#
# chmod runs unconditionally, which is what fixes case 2.
ensure_dir() {
	mkdir -p "$1" || err "failed to create directory $1"
	chmod "$2" "$1" || err "failed to set mode $2 on $1"
}

# ---------------------------------------------------------------------------
# Environment / flag contract (also printed by --help)
# ---------------------------------------------------------------------------

print_help() {
	# Full machine-discoverable env + flag contract. Printed to stdout on
	# --help so `sh -s -- --help` is self-documenting.
	cat <<'EOF'
tmh-install — installer for the thatsmyhuman CLI suite (tmh, tmh-broker, mcp-agent)

USAGE (piped):
  curl -fsSL <url>/install.sh | sh                       # user-mode (PRIMARY)
  curl -fsSL <url>/install.sh | sudo sh                  # system-wide (secondary)
  curl -fsSL <url>/install.sh | sh -s -- --help          # this help
  curl -fsSL <url>/install.sh | sh -s -- --uninstall     # remove (keeps tokens+config)

FLAGS:
  --help         Print this contract and exit 0.
  --uninstall    Remove installed binaries and symlinks, and strip the managed
                 PATH block from your shell rc files. PRESERVES HSM tokens and
                 configuration (env-file, SoftHSM tokens). Prints what it kept.

ENVIRONMENT VARIABLES:
  TMH_INSTALL_VERSION         Pin a release, e.g. v0.1.0. Default: latest redirect.
                              Use to roll back or to work around a 403/429 rate limit.
                              A pin is honoured verbatim; an UNPINNED install converges
                              to whatever the channel currently serves, in EITHER
                              direction (a yanked release self-heals backwards).
  TMH_INSTALL_PREFIX          Install prefix. Default: /opt/tmh when running as root,
                              "$HOME/.tmh" otherwise. User-mode (no sudo) is PRIMARY.
                              Must be an absolute path made of A-Z a-z 0-9 . _ - / only.
  TMH_INSTALL_BASE_URL        Override download origin (mirror / air-gap). Replaces the
                              default GitHub Releases origin.
  TMH_INSTALL_NO_LINK=1       Do not create /usr/local/bin symlinks (sudo mode), and do
                              not write the managed PATH block (user mode). "Do not wire
                              me into PATH" in both modes.
  TMH_INSTALL_NO_SHELL_PATH=1 Do not write the managed PATH block to your shell rc files
                              (user mode only). Binaries still install; the printed next
                              step uses an absolute path.
  TMH_INSTALL_NO_HSM=1        Skip SoftHSM package install + token init entirely.
  TMH_INSTALL_REQUIRE_SIGNATURE=1
                              Fail closed if minisign is unavailable (no checksum-only fallback).
  TMH_INSTALL_DRYRUN=1        Do everything EXCEPT mutating system dirs / running package
                              managers. Exercises arch map, URL construction, checksum,
                              and symlink-flip logic in a temp prefix. For CI.
  TMH_PORTAL_URL              Portal base URL. Used to render the exact next-step command
                              on success. When unset, a generic next-step message is shown.

WHAT THIS SCRIPT WRITES OUTSIDE THE PREFIX (user mode only):
  A marked block delimited by "# >>> tmh installer (managed) >>>" is PREPENDED to
  ~/.bashrc (and ~/.zshenv when zsh is in use) so that interactive shells and
  `ssh <host> 'tmh ...'` find the binaries. The previous contents are copied to
  <rc>.tmh-bak first. `--uninstall` removes the block; TMH_INSTALL_NO_SHELL_PATH=1
  (or TMH_INSTALL_NO_LINK=1) skips it. A symlinked rc is never rewritten. Sudo-mode
  installs never touch any rc file — they use /usr/local/bin symlinks instead.
  This covers BASH and ZSH only. fish, systemd units, cron, containers and sudo's
  secure_path are unaffected by design — for those, use the absolute path
  <prefix>/current/bin/<binary>, which is what this script prints on success.

RELEASE LAYOUT:
  <prefix>/releases/<label>/bin/<binary>, with <prefix>/current a symlink to the
  active release. <label> is the pinned version when pinned; otherwise the version
  the downloaded binary reports (only trusted when the minisign signature verified),
  else "latest-<first 12 hex of the tarball digest>".

MACHINE CONTRACT:
  On success, the LAST line of STDOUT is exactly:
    tmh-install: OK version=<label> prefix=<prefix> env_file=<path> binary_version=<x.y.z> release_digest=<hex12> path_persisted=<0|1>
  version= is a DIRECTORY LABEL, not a version — do not compare it as a semver and
  do not feed it back as TMH_INSTALL_VERSION. Use binary_version= for both (re-pin as
  v<binary_version>); it is empty when the version could not be trusted/probed.
  path_persisted=1 means a shell rc was updated, 0 means it was not (all warnings go
  to stderr, so this is the only way a stdout-only parser can tell).
  All human output goes to STDERR. Exit 0 without the OK line = delivery failure.

SUPPORTED TARGETS:
  linux/amd64  linux/arm64  darwin/amd64  darwin/arm64
  Minimum glibc 2.35 (Debian 12+, Ubuntu 22.04+, RHEL 9+). musl/Alpine unsupported
  (use a debian:12 container base — see the tmh-install README).

NO telemetry. NO phone-home.
EOF
}

# ---------------------------------------------------------------------------
# OS / arch detection
# ---------------------------------------------------------------------------

SUPPORTED_TARGETS="linux/amd64, linux/arm64, darwin/amd64, darwin/arm64"

detect_os() {
	# Normalize `uname -s` into "linux" or "darwin".
	os_raw=$(uname -s 2>/dev/null || echo unknown)
	case "$os_raw" in
		Linux) echo "linux" ;;
		Darwin) echo "darwin" ;;
		*)
			err "unsupported OS '$os_raw'. Supported targets: $SUPPORTED_TARGETS"
			;;
	esac
}

detect_arch() {
	# Normalize `uname -m` into "amd64" or "arm64".
	arch_raw=$(uname -m 2>/dev/null || echo unknown)
	case "$arch_raw" in
		x86_64 | amd64) echo "amd64" ;;
		aarch64 | arm64) echo "arm64" ;;
		*)
			err "unsupported architecture '$arch_raw'. Supported targets: $SUPPORTED_TARGETS"
			;;
	esac
}

# ---------------------------------------------------------------------------
# libc preflight — musl is a HARD stop; glibc-too-old is best-effort.
# ---------------------------------------------------------------------------

is_musl() {
	# Returns 0 (true) if this looks like a musl / Alpine system.
	# Alpine ships /etc/alpine-release; musl advertises itself via ldd.
	if [ -f /etc/alpine-release ]; then
		return 0
	fi
	if command -v ldd >/dev/null 2>&1; then
		if ldd --version 2>&1 | grep -qi musl; then
			return 0
		fi
	fi
	return 1
}

check_libc() {
	# Only meaningful on Linux; macOS uses its own libc.
	os="$1"
	[ "$os" = "linux" ] || return 0

	# HARD stop on musl / Alpine: the binaries are glibc-linked.
	if is_musl; then
		err "musl / Alpine libc detected — the tmh binaries are glibc-linked and will not run here.
       Run tmh inside a glibc container instead. Recommended pattern:
         FROM debian:12
         RUN apt-get update && apt-get install -y softhsm2
         COPY --from=<your-build> /opt/tmh/current/bin/ /usr/local/bin/
       See the container guidance in $README_URL"
	fi

	# Best-effort glibc minimum. If we can't determine it, WARN (do not hard-fail
	# on an inability to check — only musl is a hard stop).
	if ! command -v ldd >/dev/null 2>&1; then
		warn "could not run ldd to verify glibc >= ${MIN_GLIBC_MAJOR}.${MIN_GLIBC_MINOR}; continuing."
		return 0
	fi

	glibc_ver=$(ldd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
	if [ -z "$glibc_ver" ]; then
		warn "could not parse glibc version; minimum is ${MIN_GLIBC_MAJOR}.${MIN_GLIBC_MINOR}. Continuing."
		return 0
	fi

	glibc_major=${glibc_ver%%.*}
	glibc_minor=${glibc_ver#*.}
	if [ "$glibc_major" -lt "$MIN_GLIBC_MAJOR" ] ||
		{ [ "$glibc_major" -eq "$MIN_GLIBC_MAJOR" ] && [ "$glibc_minor" -lt "$MIN_GLIBC_MINOR" ]; }; then
		err "glibc ${glibc_ver} is too old; minimum supported is ${MIN_GLIBC_MAJOR}.${MIN_GLIBC_MINOR}
       (Debian 12+, Ubuntu 22.04+, RHEL 9+). See $README_URL"
	fi
}

# ---------------------------------------------------------------------------
# Download helpers (curl preferred, wget fallback)
# ---------------------------------------------------------------------------

http_get() {
	# http_get <url> <dest-file>. Returns non-zero on failure so callers can
	# attach a specific error message with the URL + retry hint.
	url="$1"
	dest="$2"
	if command -v curl >/dev/null 2>&1; then
		# -f: fail on HTTP >= 400 (so 403/429 propagate); -sSL: silent, show
		# errors, follow redirects (the "latest" path is a redirect).
		curl -fsSL "$url" -o "$dest"
		return $?
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$dest" "$url"
		return $?
	fi
	err "neither curl nor wget is available; cannot download. Install one and retry. $README_URL"
}

# ---------------------------------------------------------------------------
# Version / URL resolution
# ---------------------------------------------------------------------------

# resolve_base_url echoes the origin+path prefix that assets hang off of.
#   - default (no TMH_INSTALL_VERSION): the API-free "latest" redirect, which is
#     yank-safe AND immune to the anonymous GitHub API rate limit.
#   - TMH_INSTALL_VERSION set: the pinned-version download path.
#   - TMH_INSTALL_BASE_URL set: overrides the origin entirely (mirror / air-gap).
resolve_base_url() {
	if [ -n "${TMH_INSTALL_BASE_URL:-}" ]; then
		# Operator-provided mirror. Assets are expected directly under it.
		printf '%s' "${TMH_INSTALL_BASE_URL%/}"
		return 0
	fi
	if [ -n "${TMH_INSTALL_VERSION:-}" ]; then
		printf 'https://github.com/%s/releases/download/%s' "$GH_REPO" "$TMH_INSTALL_VERSION"
		return 0
	fi
	printf 'https://github.com/%s/releases/latest/download' "$GH_REPO"
}

# valid_path_component returns 0 when $1 is safe to use as a SINGLE path
# component under <prefix>/releases.
#
# It is a `case`, not a `grep -E '^...$'`, and that is the whole point: grep is
# LINE-oriented, so `printf 'v1\n../../evil' | grep -Eq '^[A-Za-z0-9._-]+$'`
# SUCCEEDS — the first line matches. The old validate_version used exactly that
# form, and the value flows into `mkdir -p` (which happily traverses the `..`
# components and creates a directory outside the intended parent) and then into
# `rm -rf`. A `case` tests the ENTIRE value, newlines included.
#
# "." and ".." pass the charset test but are traversal, so they are rejected by
# name: `releases/..` is the prefix itself, and `rm -rf` on it would take the
# whole install with it.
valid_path_component() {
	case "$1" in
		"" | "." | "..") return 1 ;;
		*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

# validate_version rejects a TMH_INSTALL_VERSION that is not a safe single path
# component. The value flows into mkdir, rm -rf and ln -s.
validate_version() {
	[ -n "${TMH_INSTALL_VERSION:-}" ] || return 0
	if ! valid_path_component "$TMH_INSTALL_VERSION"; then
		err "invalid TMH_INSTALL_VERSION — allowed characters are A-Z a-z 0-9 . _ - only, and it may not be '.' or '..'.
       cause: the value becomes a directory name under <prefix>/releases, so a slash, space, newline or '..' would escape it.
       fix: pin a published tag, e.g. TMH_INSTALL_VERSION=v0.1.0 (see $RELEASES_URL)"
	fi
}

# validate_prefix enforces that the install prefix is an absolute, traversal-free
# path built from a conservative charset.
#
# This became REQUIRED (not merely nice) when the installer started writing the
# prefix into shell startup files: as a quoted argument to mkdir/ln/mv a weird
# prefix is only data, but written into ~/.bashrc it becomes CODE that every
# future shell runs. The emitted block single-quotes the path, which is safe
# precisely because "'" is outside the charset allowed here.
#
# It also guards `--uninstall`, which runs `rm -rf "$prefix/releases"`.
validate_prefix() {
	p="$1"
	case "$p" in
		/*) : ;;
		*)
			err "install prefix must be an ABSOLUTE path (got: $p)
       cause: relative prefixes resolve against whatever directory the shell happens to be in.
       fix: TMH_INSTALL_PREFIX=\"\$HOME/.tmh\" (user mode) or /opt/tmh (system)"
			;;
	esac
	case "$p" in
		*[!A-Za-z0-9._/-]*)
			err "install prefix contains characters this installer refuses to handle
       cause: the prefix is written into your shell startup files, where quotes, spaces, newlines and \$(...) would become executable code.
       allowed: A-Z a-z 0-9 . _ - /
       fix: TMH_INSTALL_PREFIX=/opt/tmh (or any path built only from those characters)"
			;;
	esac
	case "/$p/" in
		*/../*)
			err "install prefix contains a '..' component (got: $p)
       cause: '..' makes the install target depend on where the path is resolved from, and the prefix is passed to rm -rf on --uninstall.
       fix: pass the fully-resolved path, e.g. TMH_INSTALL_PREFIX=\"\$HOME/.tmh\""
			;;
	esac
}

# validate_base_url enforces the transport for a mirror override. Plain http is
# a downgrade risk (the checksum comes from the same origin), so require https
# EXCEPT for explicit loopback origins (used by the CI fixture server). Any
# other non-https origin is rejected loudly. Also warns on every override.
validate_base_url() {
	[ -n "${TMH_INSTALL_BASE_URL:-}" ] || return 0
	url="$TMH_INSTALL_BASE_URL"
	case "$url" in
		https://*)
			: # https is always allowed
			;;
		http://localhost | http://localhost/* | http://localhost:* \
			| http://127.0.0.1 | http://127.0.0.1/* | http://127.0.0.1:* \
			| "http://[::1]" | "http://[::1]/"* | "http://[::1]:"*)
			warn "TMH_INSTALL_BASE_URL is a loopback http origin ($url) — allowed for local testing only."
			;;
		*)
			err "TMH_INSTALL_BASE_URL must use https:// (loopback http is allowed only for localhost/127.0.0.1/[::1]).
       Refusing insecure origin: $url
       An http mirror is a downgrade risk because checksums are fetched from the same origin. $README_URL"
			;;
	esac
	warn "using overridden download origin TMH_INSTALL_BASE_URL=$url (not the default signed GitHub Releases)."
}

# ---------------------------------------------------------------------------
# Checksum verification (ALWAYS runs — trust-critical).
# ---------------------------------------------------------------------------

# sha256 <file> echoes the lowercase hex digest, trying the three common tools.
sha256() {
	f="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$f" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$f" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		# openssl prints "SHA256(file)= <hex>" or "<hex>"; take the last field.
		openssl dgst -sha256 "$f" | awk '{print $NF}'
	else
		err "no sha256 tool found (need sha256sum, shasum, or openssl). $README_URL"
	fi
}

# short_digest echoes the first 12 characters of a sha256 hex digest, after
# proving the input really is one. The result becomes a path component (the
# release label of an unsigned/unprobeable install, and the disambiguating
# suffix of a colliding one), so it is validated rather than assumed.
short_digest() {
	h="$1"
	case "$h" in
		*[!0-9a-f]*)
			err "internal: sha256 helper returned a non-hex digest. $README_URL"
			;;
	esac
	[ "${#h}" -eq 64 ] ||
		err "internal: sha256 helper returned a ${#h}-character digest, expected 64. $README_URL"
	printf '%s' "$h" | cut -c1-12
}

# verify_checksum <tarball> <sha256sums-file> <asset-name>
# Extracts the single expected line for OUR tarball from SHA256SUMS, computes the
# actual digest, and ABORTS on any mismatch. Nothing is installed on failure.
verify_checksum() {
	tarball="$1"
	sums="$2"
	asset="$3"

	# The SHA256SUMS file has "<hex>  <filename>" lines. Match on the exact asset
	# name to avoid picking up a substring of another asset. We compare the whole
	# filename field, not a grep substring.
	expected=$(awk -v want="$asset" '$2 == want {print $1; found=1} END {if (!found) exit 1}' "$sums") ||
		err "asset '$asset' not listed in SHA256SUMS — cannot verify integrity. Aborting. $README_URL"

	actual=$(sha256 "$tarball")

	if [ "$expected" != "$actual" ]; then
		err "CHECKSUM MISMATCH for $asset — possible tampering or corrupt download.
       expected: $expected
       actual:   $actual
       NOTHING was installed. Do not run the downloaded file. $README_URL"
	fi
	log "checksum OK: $asset"
}

# ---------------------------------------------------------------------------
# Signature verification (minisign) — trust-critical.
# ---------------------------------------------------------------------------

# verify_signature <sha256sums-file> <sha256sums-sig-file>
# minisign verifies SHA256SUMS against the pinned public key. Because the tarball
# digest is bound into SHA256SUMS and that file is signed, verifying the file
# transitively authenticates the tarball.
#   - minisign present: verify; on failure ABORT.
#   - minisign absent: WARN + checksum-only, UNLESS TMH_INSTALL_REQUIRE_SIGNATURE=1
#     which makes it fail-closed.
# On the ONE branch that actually verified, SIGNATURE_VERIFIED=1. Nothing else in
# this file may set it: it is what gates executing the downloaded binary to read
# its version.
verify_signature() {
	sums="$1"
	sig="$2"

	if ! command -v minisign >/dev/null 2>&1; then
		if [ "${TMH_INSTALL_REQUIRE_SIGNATURE:-}" = "1" ]; then
			err "minisign not found but TMH_INSTALL_REQUIRE_SIGNATURE=1 is set (fail-closed).
       Install minisign, or unset the variable to allow checksum-only. $README_URL"
		fi
		warn "minisign not found — proceeding with checksum-only verification."
		warn "For the strongest guarantee, install minisign (or set TMH_INSTALL_REQUIRE_SIGNATURE=1 to require it)."
		return 0
	fi

	if [ "$MINISIGN_PUBLIC_KEY" = "RWQ_PLACEHOLDER_REPLACE_AT_RELEASE" ]; then
		# The build was shipped without a real pinned key. Fail closed if the
		# operator demanded signatures; otherwise warn loudly and fall back.
		if [ "${TMH_INSTALL_REQUIRE_SIGNATURE:-}" = "1" ]; then
			err "pinned minisign public key is a placeholder; cannot satisfy TMH_INSTALL_REQUIRE_SIGNATURE=1. $README_URL"
		fi
		warn "pinned minisign public key is a placeholder — skipping signature verification."
		return 0
	fi

	# -V verify, -P <pubkey> pins the key inline, -m the signed message,
	# -x the detached signature file.
	if minisign -V -P "$MINISIGN_PUBLIC_KEY" -m "$sums" -x "$sig" >/dev/null 2>&1; then
		SIGNATURE_VERIFIED=1
		log "signature OK: SHA256SUMS verified against pinned minisign key"
	else
		err "SIGNATURE VERIFICATION FAILED for SHA256SUMS — possible tampering.
       NOTHING was installed. $README_URL"
	fi
}

# ---------------------------------------------------------------------------
# Privilege / mode detection
# ---------------------------------------------------------------------------

# is_tty returns 0 when stdin is a terminal. A piped `curl | sh` is NOT a tty,
# so we must never prompt — we fail fast with an exact handoff command instead.
is_tty() {
	[ -t 0 ]
}

# ---------------------------------------------------------------------------
# Install: staging -> release dir -> atomic symlink flip
# ---------------------------------------------------------------------------

BINARIES="tmh tmh-broker mcp-agent"

# validate_binaries <dir> ensures all three binaries are present & executable.
validate_binaries() {
	dir="$1"
	for b in $BINARIES; do
		if [ ! -f "$dir/$b" ]; then
			err "binary '$b' missing from downloaded archive — refusing to install a partial set. $README_URL"
		fi
		# Ensure the executable bit; tar should preserve it but be defensive.
		chmod +x "$dir/$b" 2>/dev/null || true
		if [ ! -x "$dir/$b" ]; then
			err "binary '$b' is not executable after unpack. $README_URL"
		fi
	done
}

# probe_version <dir> echoes the version the freshly-unpacked tmh binary reports.
#
# It parses against a STRICT GRAMMAR rather than "field 2". internal/version's
# String() always emits exactly `tmh <version> (<commit>, <date>)` on ONE line,
# so anything else — a warning line, a banner, a second record, an empty version
# field — is rejected outright. The result becomes a directory name that flows
# into mkdir, rm -rf and ln -s, so it is charset-checked with `case` (see
# valid_path_component for why not grep) before it is echoed.
#
# The caller only runs this when SIGNATURE_VERIFIED=1: without a verified
# signature these bytes are merely checksum-consistent with an unauthenticated
# SHA256SUMS, and executing them to ask what they are would be trusting the
# thing being verified.
probe_version() {
	d="$1"
	[ -x "$d/tmh" ] || return 1
	# Written as `if out=$(...)` so a non-zero exit cannot abort the script under
	# `set -e` before the caller's fallback is reached.
	if ! out=$("$d/tmh" --version 2>/dev/null); then
		return 1
	fi
	[ -n "$out" ] || return 1
	# Exactly one line: reject extra output around an otherwise valid record.
	case "$out" in
		*"
"*) return 1 ;;
	esac
	case "$out" in
		"tmh "*" ("*", "*")") : ;;
		*) return 1 ;;
	esac
	v=${out#tmh }
	v=${v%% *}
	valid_path_component "$v" || return 1
	printf '%s' "$v"
}

# release_label <version> normalizes a probed version into a release label, so
# that an unpinned install and TMH_INSTALL_VERSION=v0.1.2 share one release dir.
# A dev build (version "dev") is left alone.
release_label() {
	case "$1" in
		[0-9]*) printf 'v%s' "$1" ;;
		*) printf '%s' "$1" ;;
	esac
}

# write_meta <release-dir> <tarball-digest> <label> <probe_ok> <signature_verified>
#
# The RAW probe output is deliberately not stored: it is untrusted output from a
# downloaded binary, and a newline in it would corrupt this KEY=VALUE file.
# probe_ok carries the only bit that matters. Every value written here is either
# hex or has already passed valid_path_component.
write_meta() {
	d="$1"
	{
		printf 'tarball_sha256=%s\n' "$2"
		printf 'version=%s\n' "$3"
		printf 'probe_ok=%s\n' "$4"
		printf 'signature_verified=%s\n' "$5"
		for b in $BINARIES; do
			printf 'bin_%s_sha256=%s\n' "$b" "$(sha256 "$d/bin/$b")"
		done
	} >"$d/$META_FILE" || err "failed to write release metadata $d/$META_FILE. $README_URL"
	chmod 0644 "$d/$META_FILE" 2>/dev/null || true
}

# read_meta <release-dir> <key> echoes a value from the release metadata, or
# nothing. The file is parsed with awk and NEVER sourced: it lives in a directory
# an install wrote, and `.`-ing it would turn a corrupted line into shell code.
read_meta() {
	[ -f "$1/$META_FILE" ] || return 0
	awk -F= -v k="$2" '$1 == k { print $2; exit }' "$1/$META_FILE" 2>/dev/null || true
}

# release_is_intact <release-dir> <tarball-digest> returns 0 only when the release
# was built from this exact tarball AND every installed binary still hashes to
# what was recorded.
#
# The binary check is the difference between an honest no-op and a lie: a guard
# that only asks "is there an executable file here" (what this script used to do)
# passes on a locally modified — or truncated, or swapped — current/bin/tmh, so
# re-running the installer could never repair one.
release_is_intact() {
	d="$1"
	want_tarball="$2"
	recorded=$(read_meta "$d" tarball_sha256)
	[ -n "$recorded" ] || return 1
	[ "$recorded" = "$want_tarball" ] || return 1
	for b in $BINARIES; do
		[ -x "$d/bin/$b" ] || return 1
		want=$(read_meta "$d" "bin_${b}_sha256")
		[ -n "$want" ] || return 1
		[ "$want" = "$(sha256 "$d/bin/$b")" ] || return 1
	done
	return 0
}

# acquire_install_lock serializes installs per prefix. Two concurrent installers
# would otherwise interleave through the collision branch, the symlink flip and
# the legacy retirement. `mkdir` is the POSIX atomic test-and-set. A stale lock
# is REPORTED with the exact path to remove, never silently stolen.
acquire_install_lock() {
	lock="$1/.install.lock"
	if mkdir "$lock" 2>/dev/null; then
		CLEANUP_LOCKDIR="$lock"
		return 0
	fi
	err "another install is in progress for this prefix
       cause: a concurrent run holds the lock at $lock (or a previous run was killed before releasing it).
       fix: wait for the other install to finish; if none is running, remove the stale lock and re-run:
         rmdir '$lock'"
}

# point_current <prefix> <release-name> flips <prefix>/current.
#
# Create a uniquely-named temp symlink, then rename it over 'current'. A PLAIN
# `mv -f newlink current` is wrong: on an upgrade 'current' is a symlink to the
# previous release DIRECTORY, and mv FOLLOWS it and moves newlink INTO that
# directory (leaving 'current' pointing at the old release) on both GNU and BSD.
#
# `mv -h` (BSD) and `mv -T` (GNU) are exactly the "do not follow the destination
# symlink" flag, so either turns this into a SINGLE rename(2) — no window in
# which 'current' does not exist. Neither flag exists on the other platform, and
# an unknown option is rejected during option parsing before mv touches
# anything, so trying both in turn is safe. The rm->mv pair is kept as the last
# resort for a mv with neither flag; it is correct but leaves a microscopic
# install-time window where 'current' is absent.
# NOTE the pc_ prefixes. POSIX sh has no `local`, so a parameter named `prefix`
# here would overwrite main's `prefix` — which it did: called with the DRYRUN
# temp prefix, it left main reporting that temp dir on the OK line instead of the
# real install prefix.
point_current() {
	pc_prefix="$1"
	pc_name="$2"
	pc_link="$pc_prefix/current"
	pc_tmp="$pc_link.tmp.$$"
	ln -s "releases/$pc_name" "$pc_tmp"
	if mv -h "$pc_tmp" "$pc_link" 2>/dev/null; then
		return 0
	fi
	if mv -T "$pc_tmp" "$pc_link" 2>/dev/null; then
		return 0
	fi
	rm -f "$pc_link"
	mv -f "$pc_tmp" "$pc_link"
}

# retire_legacy_latest removes an unreferenced <prefix>/releases/latest left by a
# pre-#336 installer, which labelled EVERY unpinned install "latest" and so could
# never tell one release from another. Refuses when 'latest' is the live label or
# is still the target of 'current'.
# rl_ prefixes for the same reason as point_current's pc_: these would otherwise
# be main's and install_release's variables.
retire_legacy_latest() {
	rl_prefix="$1"
	rl_label="$2"
	[ "$rl_label" != "latest" ] || return 0
	rl_legacy="$rl_prefix/releases/latest"
	[ -d "$rl_legacy" ] || return 0
	[ "$(readlink "$rl_prefix/current" 2>/dev/null || true)" != "releases/latest" ] || return 0
	rm -rf "$rl_legacy"
	log "retired the legacy 'latest' release dir (superseded by $rl_label): $rl_legacy"
}

# install_release performs the trust-critical placement:
#   1. Unpack the verified tarball into an immutable staging dir.
#   2. Validate all three binaries, then resolve the release LABEL.
#   3. No-op only if this exact tarball is already installed AND intact.
#   4. Build the release completely under a temp name and publish by RENAME, so
#      an interruption can never leave a half-filled dir under 'current'.
#   5. Atomically flip the <prefix>/current symlink.
#
# install_release <prefix> <pinned-version-or-empty> <tarball> <dir-mode>
install_release() {
	prefix="$1"
	pinned="$2"
	tarball="$3"
	# Mode for every directory created below. Passed in rather than read from a
	# global so the dependency is visible at the call site (issue #333).
	dir_mode="$4"

	releases_dir="$prefix/releases"

	tarball_digest=$(sha256 "$tarball")
	RELEASE_DIGEST=$(short_digest "$tarball_digest")

	if [ "${TMH_INSTALL_DRYRUN:-}" = "1" ]; then
		# DRYRUN: exercise the unpack + validation + symlink-flip logic entirely
		# inside a throwaway temp prefix; never touch the real system dirs, and
		# never execute the downloaded binary.
		if [ -n "$pinned" ]; then
			INSTALLED_VERSION="$pinned"
		else
			INSTALLED_VERSION="latest-$RELEASE_DIGEST"
		fi
		dry_prefix=$(mktemp -d 2>/dev/null || mktemp -d -t tmhinstall.XXXXXX)
		log "[dryrun] using temp prefix $dry_prefix (real prefix would be $prefix)"
		dry_target="$dry_prefix/releases/$INSTALLED_VERSION"
		# Same helper as the real path, so a dry run exercises it too.
		ensure_dir "$dry_target" "$dir_mode"
		tar -xzf "$tarball" -C "$dry_target"
		flatten_if_nested "$dry_target"
		validate_binaries "$dry_target"
		point_current "$dry_prefix" "$INSTALLED_VERSION"
		log "[dryrun] symlink flip OK: $dry_prefix/current -> releases/$INSTALLED_VERSION"
		rm -rf "$dry_prefix"
		return 0
	fi

	# Normalize the prefix chain BEFORE anything below can return early, so a
	# re-run heals a prefix an earlier install created group-writable even when
	# it has nothing else to do (issue #333).
	ensure_dir "$prefix" "$dir_mode"
	ensure_dir "$releases_dir" "$dir_mode"
	acquire_install_lock "$prefix"

	# Unpack into an immutable staging dir first, BEFORE the same-version guard:
	# the label may have to come from the binary itself, and a guard that runs
	# first can only compare directory names. Cleanup is handled by the trap on
	# every path, including the no-op return.
	staging=$(mktemp -d 2>/dev/null || mktemp -d -t tmhinstall.XXXXXX)
	CLEANUP_STAGING="$staging"
	tar -xzf "$tarball" -C "$staging" ||
		err "failed to unpack $tarball. $README_URL"
	flatten_if_nested "$staging"
	validate_binaries "$staging"

	# --- Resolve the release label ---------------------------------------
	# The DIGEST is the authority (SHA256SUMS is minisign-signed and binds it);
	# the version string is UX. So the label is chosen for legibility and the
	# digest does the correctness work below, never the other way round.
	probe_ok=0
	if [ "$SIGNATURE_VERIFIED" = "1" ]; then
		BINARY_VERSION=$(probe_version "$staging") || BINARY_VERSION=""
		[ -z "$BINARY_VERSION" ] || probe_ok=1
	fi

	if [ -n "$pinned" ]; then
		label="$pinned"
		if [ "$probe_ok" = "1" ] && [ "$(release_label "$BINARY_VERSION")" != "$pinned" ]; then
			warn "pinned version '$pinned' but the downloaded tmh reports '$BINARY_VERSION'.
       cause: the release assets for that tag were built from a different version, or the tag was re-cut.
       effect: installing anyway, under the pinned label '$pinned' — the binaries are the ones that tag serves.
       fix: nothing needed to proceed; report the mismatch if the tag is supposed to be immutable."
		fi
	elif [ "$probe_ok" = "1" ]; then
		label=$(release_label "$BINARY_VERSION")
	else
		label="latest-$RELEASE_DIGEST"
		if [ "$SIGNATURE_VERIFIED" = "1" ]; then
			warn "could not read a usable version from the downloaded tmh binary.
       cause: 'tmh --version' failed or did not print exactly 'tmh <version> (<commit>, <date>)'.
       effect: this release is labelled '$label' (its content digest) instead of a version; the install itself is unaffected.
       fix: none required. Pin a tag (TMH_INSTALL_VERSION=v0.1.0) if you want a version-named release dir."
		else
			warn "installing without a verified signature, so the binary's self-reported version is not trusted.
       cause: minisign was unavailable, the signature file was missing, or the pinned key is a placeholder (checksum-only verification).
       effect: this release is labelled '$label' (its content digest) instead of a version.
       fix: install minisign and re-run — or set TMH_INSTALL_REQUIRE_SIGNATURE=1 to refuse checksum-only installs outright."
		fi
	fi

	# --- Same-release guard ------------------------------------------------
	target_dir="$releases_dir/$label"
	final_name="$label"
	if [ -d "$target_dir" ]; then
		if release_is_intact "$target_dir" "$tarball_digest"; then
			log "release $label is already installed from this exact tarball ($RELEASE_DIGEST) — no-op"
			# Heal the release dir's own mode on this path too. It is skipped by
			# the hardening above, and it is the chain trustedExecPath walks for
			# <prefix>/current/bin/<binary> — so leaving it group-writable keeps
			# the binaries in a directory another local user could swap
			# (issues #333/#334). Modes only: the release dir's CONTENTS stay
			# untouched, per the never-mutate-a-valid-release rule.
			ensure_dir "$target_dir" "$dir_mode"
			ensure_dir "$target_dir/bin" "$dir_mode"
			if [ "$(readlink "$prefix/current" 2>/dev/null || true)" != "releases/$label" ]; then
				point_current "$prefix" "$label"
				log "re-pointed current -> releases/$label"
			fi
			retire_legacy_latest "$prefix" "$label"
			INSTALLED_VERSION="$label"
			return 0
		fi
		# Any digest read back out of a metadata file is re-validated as a full
		# 64-character lowercase hex string before it is compared or, below,
		# shortened into a path component.
		recorded=$(read_meta "$target_dir" tarball_sha256)
		case "$recorded" in
			"" | *[!0-9a-f]*) recorded="" ;;
		esac
		[ "${#recorded}" -eq 64 ] || recorded=""
		if [ -n "$recorded" ] && [ "$recorded" != "$tarball_digest" ]; then
			# Same label, different content. Never touch the existing release:
			# install alongside it and let the symlink flip be the ONLY mutation
			# of live state. This keeps the runbook's `ln -sfn` recovery working
			# (both candidates stay on disk) and is idempotent by construction —
			# a repeat of the same collision resolves to the same path and takes
			# the no-op branch above.
			final_name="$label-$RELEASE_DIGEST"
			warn "release label '$label' already exists with DIFFERENT content.
       cause: the channel now serves a different build under the same version (a re-cut tag, or a rebuilt release).
       effect: installing the new build at releases/$final_name (digest $RELEASE_DIGEST); the existing releases/$label (digest $(short_digest "$recorded")) is left untouched, and current points at the new one.
       fix: no action needed. To go back: ln -sfn '$target_dir' '$prefix/current'"
			target_dir="$releases_dir/$final_name"
			if [ -d "$target_dir" ] && release_is_intact "$target_dir" "$tarball_digest"; then
				log "release $final_name is already installed from this exact tarball ($RELEASE_DIGEST) — no-op"
				ensure_dir "$target_dir" "$dir_mode"
				ensure_dir "$target_dir/bin" "$dir_mode"
				point_current "$prefix" "$final_name"
				retire_legacy_latest "$prefix" "$final_name"
				INSTALLED_VERSION="$final_name"
				return 0
			fi
		fi
	fi

	# --- Build completely, then publish by rename --------------------------
	# Nothing under releases/<final_name> is ever populated incrementally, so an
	# interruption cannot leave a partially-filled directory that current points
	# at. The staging dir is not renamed directly because it lives in $TMPDIR,
	# which may be a different filesystem (mv would degrade to a copy).
	build_dir="$releases_dir/.build.$$"
	rm -rf "$build_dir"
	ensure_dir "$build_dir" "$dir_mode"
	ensure_dir "$build_dir/bin" "$dir_mode"
	for b in $BINARIES; do
		mv "$staging/$b" "$build_dir/bin/$b"
	done
	# $final_name, not $label: on a collision the release is published under the
	# digest-suffixed name, and the metadata has to name the directory it is in.
	write_meta "$build_dir" "$tarball_digest" "$final_name" "$probe_ok" "$SIGNATURE_VERIFIED"
	rm -rf "$staging"
	CLEANUP_STAGING=""

	if [ -e "$target_dir" ]; then
		# Replacing an untrustworthy release (no metadata, or tampered binaries)
		# under its own name. POSIX has no atomic directory swap, so this is two
		# renames with a window between them in which the path does not exist —
		# far narrower than an `rm -rf` would be, but not zero. If the second
		# rename fails, put the old directory back rather than leaving 'current'
		# pointing at nothing.
		old_dir="$releases_dir/.replaced.$$"
		rm -rf "$old_dir"
		mv "$target_dir" "$old_dir"
		if ! mv "$build_dir" "$target_dir"; then
			mv "$old_dir" "$target_dir" 2>/dev/null || true
			err "failed to publish the new release at $target_dir — the previous one was restored. $README_URL"
		fi
		rm -rf "$old_dir"
	else
		mv "$build_dir" "$target_dir"
	fi

	point_current "$prefix" "$final_name"
	log "installed $final_name -> $target_dir; current -> releases/$final_name"
	retire_legacy_latest "$prefix" "$final_name"
	INSTALLED_VERSION="$final_name"
}

# flatten_if_nested handles archives that unpack into a single top-level dir
# (e.g. tmh_v0.1.0_linux_amd64/tmh) by hoisting the binaries up one level.
flatten_if_nested() {
	d="$1"
	# If none of the binaries are at the top level but exactly one subdir exists
	# that contains them, move its contents up.
	if [ -f "$d/tmh" ]; then
		return 0
	fi
	inner=""
	for sub in "$d"/*/; do
		[ -d "$sub" ] || continue
		if [ -f "$sub/tmh" ]; then
			inner="$sub"
			break
		fi
	done
	if [ -n "$inner" ]; then
		# Move all regular files up. (POSIX mv of the glob contents.)
		for f in "$inner"*; do
			mv "$f" "$d/"
		done
	fi
}

# create_bin_symlinks (sudo mode) links /usr/local/bin/<binary> -> current/bin.
create_bin_symlinks() {
	prefix="$1"
	if [ "${TMH_INSTALL_NO_LINK:-}" = "1" ]; then
		log "TMH_INSTALL_NO_LINK=1 — skipping /usr/local/bin symlinks"
		return 0
	fi
	if [ "${TMH_INSTALL_DRYRUN:-}" = "1" ]; then
		log "[dryrun] would link /usr/local/bin/{$(echo "$BINARIES" | tr ' ' ',')} -> $prefix/current/bin/*"
		return 0
	fi
	mkdir -p /usr/local/bin
	for b in $BINARIES; do
		ln -sf "$prefix/current/bin/$b" "/usr/local/bin/$b"
	done
	log "linked /usr/local/bin/{$(echo "$BINARIES" | tr ' ' ',')}"
}

# ---------------------------------------------------------------------------
# PATH persistence (user mode) — issue #337.
#
# A user-mode install used to put NOTHING on PATH while printing `tmh enroll` as
# the next step, so the very next command in every guide failed. One mechanism
# fixes it: a marker-delimited block PREPENDED to the shell rc.
#
# PREPENDED, specifically, because Debian's stock ~/.bashrc opens with
#   case $- in *i*) ;; *) return;; esac
# and `ssh <host> 'tmh ...'` is exactly the non-interactive case that early-return
# discards. A block appended at the bottom is unreachable for every ssh-driven
# agent — which is the case that matters here.
#
# What this does NOT reach, stated so nobody reads more into it: systemd units,
# cron, containers, sudo's secure_path, fish, or an environment-scrubbed agent
# runtime. Those need the absolute path, which is why print_next_step always
# prints one.
# ---------------------------------------------------------------------------

# emit_path_block <bin-dir> writes the managed block to stdout.
#
# The prefix is written EXPANDED and SINGLE-QUOTED, not as $HOME: the prefix is
# configurable and may point anywhere. Single quotes mean nothing re-expands at
# shell startup, which is safe precisely because validate_prefix has already
# excluded "'" (and everything else outside A-Za-z0-9._-/) from the value.
# shellcheck disable=SC2016  # $PATH must stay LITERAL: it is evaluated by the
# user's shell at startup, not by this installer.
emit_path_block() {
	printf '%s\n' "$PATH_BLOCK_BEGIN"
	printf '%s\n' "# Added by the tmh installer (issue #337). Deliberately ABOVE any"
	printf '%s\n' "# non-interactive early-return, so \`ssh <host> 'tmh ...'\` sees it too."
	printf '%s\n' "# Remove with \`install.sh --uninstall\`, or delete this block."
	printf '%s\n' 'case ":$PATH:" in'
	printf '  *":%s:"*) ;;\n' "$1"
	printf '  *) PATH=%s:"$PATH" ;;\n' "'$1'"
	printf '%s\n' 'esac'
	printf '%s\n' 'export PATH'
	printf '%s\n' "$PATH_BLOCK_END"
}

# rc_block_bounds <rc> echoes "<begin-line> <end-line>" for the single managed
# block in $rc, "0 0" when there is none, and returns non-zero when the markers
# are malformed.
#
# Marker handling is deliberately strict. An awk/sed range over an unmatched or
# reversed pair silently eats the rest of the file — and the file in question is
# the user's shell rc.
rc_block_bounds() {
	rc="$1"
	if [ ! -f "$rc" ]; then
		printf '0 0'
		return 0
	fi
	nb=$(grep -Fxc "$PATH_BLOCK_BEGIN" "$rc" 2>/dev/null || true)
	ne=$(grep -Fxc "$PATH_BLOCK_END" "$rc" 2>/dev/null || true)
	if [ "$nb" = "0" ] && [ "$ne" = "0" ]; then
		printf '0 0'
		return 0
	fi
	if [ "$nb" != "1" ] || [ "$ne" != "1" ]; then
		return 1
	fi
	bl=$(grep -Fxn "$PATH_BLOCK_BEGIN" "$rc" | cut -d: -f1)
	el=$(grep -Fxn "$PATH_BLOCK_END" "$rc" | cut -d: -f1)
	[ "$bl" -lt "$el" ] || return 1
	printf '%s %s' "$bl" "$el"
}

# rewrite_rc <rc> <mode> <bin-dir>
#   mode=install -> managed block prepended (or the existing one replaced)
#   mode=remove  -> managed block stripped, leaving the rest byte-identical
#
# The rewrite is atomic and mode-preserving: stage in the rc's OWN directory so
# the final `mv` is a same-filesystem rename (a cross-device mv degrades to
# copy-then-unlink and loses the guarantee), `cp -p` the original first so the
# temp inherits mode/ownership, and only then rename over the original. The
# user's rc is never observed truncated.
#
# The unchanged parts are copied with head/tail rather than reprinted line by
# line, so a file with NO trailing newline keeps not having one — which is what
# lets --uninstall restore the original byte for byte.
rewrite_rc() {
	rc="$1"
	mode="$2"
	bin="$3"

	if [ -L "$rc" ]; then
		warn "$rc is a symlink — refusing to rewrite it.
       cause: dotfile managers (stow, chezmoi, a dotfiles repo) symlink shell rc files, and replacing the file would detach this host from the managed original.
       effect: PATH was NOT persisted for that shell.
       fix: add this line to the real file yourself:
         export PATH=\"$bin:\$PATH\""
		return 1
	fi
	if [ -e "$rc" ] && [ ! -w "$rc" ]; then
		warn "$rc is not writable — the install SUCCEEDED but PATH was not persisted there.
       cause: the file is read-only for this user (mode, ownership, or an immutable flag).
       fix: run tmh by absolute path, or add this line to $rc yourself:
         export PATH=\"$bin:\$PATH\""
		return 1
	fi
	dir=$(dirname "$rc")
	if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
		warn "cannot write in $dir — the install SUCCEEDED but PATH was not persisted.
       cause: the directory is missing or not writable for this user (read-only home?).
       fix: run tmh by absolute path, or add this line to your shell rc yourself:
         export PATH=\"$bin:\$PATH\""
		return 1
	fi

	# ONE snapshot is the source of truth for both the marker bounds and the
	# copied-through content. Reading the live file twice would mean line numbers
	# computed from one version of it could be applied to another (an editor or a
	# dotfile manager writing concurrently), which is how a range-based rewrite
	# deletes lines it was never meant to touch. cp -p also carries the mode and
	# ownership forward, so the published file keeps them.
	snap="$dir/.tmh-rc.snap.$$"
	tmp="$dir/.tmh-rc.tmp.$$"
	rm -f "$snap" "$tmp"
	if [ -f "$rc" ]; then
		if ! cp -p "$rc" "$snap" 2>/dev/null; then
			warn "could not snapshot $rc — PATH was not persisted there.
       cause: cp failed (permissions, or no space in $dir).
       fix: add this line to $rc yourself: export PATH=\"$bin:\$PATH\""
			return 1
		fi
	fi

	if ! bounds=$(rc_block_bounds "$snap"); then
		warn "$rc contains a malformed tmh installer block — refusing to rewrite it.
       cause: expected exactly one '$PATH_BLOCK_BEGIN' ... '$PATH_BLOCK_END' pair in that order; found an unmatched, reversed or duplicated marker.
       effect: the file was left exactly as it is; PATH was not persisted there.
       fix: repair or delete the marker lines by hand, then re-run the installer."
		rm -f "$snap"
		return 1
	fi
	bl=${bounds% *}
	el=${bounds#* }

	if [ "$mode" = "remove" ] && [ "$bl" = "0" ]; then
		rm -f "$snap"
		return 1
	fi

	if [ -f "$snap" ]; then
		cp -p "$snap" "$tmp" 2>/dev/null || {
			warn "could not stage a rewrite of $rc — PATH was not persisted there.
       fix: add this line to $rc yourself: export PATH=\"$bin:\$PATH\""
			rm -f "$snap"
			return 1
		}
	fi

	if ! rc_content "$snap" "$mode" "$bin" "$bl" "$el" >"$tmp"; then
		warn "failed to stage the rewrite of $rc — the original is untouched and PATH was not persisted there."
		rm -f "$snap" "$tmp"
		return 1
	fi

	# Verify before publishing. A block-aware rewrite that ate the file is the
	# failure mode worth spending a check on.
	if [ "$mode" = "install" ]; then
		if [ ! -s "$tmp" ] ||
			[ "$(grep -Fxc "$PATH_BLOCK_BEGIN" "$tmp")" != "1" ] ||
			[ "$(grep -Fxc "$PATH_BLOCK_END" "$tmp")" != "1" ]; then
			warn "staged rewrite of $rc failed its own sanity check — discarding it, $rc is untouched."
			rm -f "$snap" "$tmp"
			return 1
		fi
		# Only for a pure prepend: when an existing block is being REPLACED it may
		# itself have been the file's last line, so a differing tail is legitimate
		# there and the marker-count check above is what covers that case.
		if [ "$bl" = "0" ] && [ -s "$snap" ] &&
			[ "$(tail -n 1 "$tmp")" != "$(tail -n 1 "$snap")" ]; then
			warn "staged rewrite of $rc lost its trailing content — discarding it, $rc is untouched."
			rm -f "$snap" "$tmp"
			return 1
		fi
	fi

	if [ ! -e "$rc" ]; then
		chmod 0644 "$tmp" 2>/dev/null || true
	fi
	if ! mv -f "$tmp" "$rc"; then
		warn "could not replace $rc — PATH was not persisted there.
       fix: add this line to $rc yourself: export PATH=\"$bin:\$PATH\""
		rm -f "$snap" "$tmp"
		return 1
	fi
	# The snapshot IS the immediately-previous state, so it becomes the backup.
	if [ -f "$snap" ]; then
		mv -f "$snap" "$rc.tmh-bak" ||
			warn "could not keep the backup $rc.tmh-bak; the rewrite itself succeeded."
		rm -f "$snap"
	fi
	return 0
}

# rc_content <snapshot> <mode> <bin-dir> <begin-line> <end-line> writes the new
# rc to stdout: the managed block (install mode only) followed by the snapshot
# with any existing block removed.
#
# The unchanged parts are copied with head/tail rather than reprinted line by
# line, so a file with NO trailing newline keeps not having one — which is what
# lets --uninstall restore the original byte for byte.
#
# Every producer is checked explicitly. This function is called as the condition
# of an `if !`, which disables errexit inside it, so a `head` that failed while
# the following `tail` succeeded would otherwise report success and publish an rc
# missing its leading content.
rc_content() {
	snap="$1"
	mode="$2"
	bin="$3"
	bl="$4"
	el="$5"
	if [ "$mode" = "install" ]; then
		emit_path_block "$bin" || return 1
	fi
	[ -f "$snap" ] || return 0
	if [ "$bl" != "0" ]; then
		if [ "$bl" -gt 1 ]; then
			head -n "$((bl - 1))" "$snap" || return 1
		fi
		tail -n "+$((el + 1))" "$snap" || return 1
	else
		cat "$snap" || return 1
	fi
	return 0
}

# resolve_shell_rcs sets RC_BASH / RC_ZSH to the rc files to manage: always
# ~/.bashrc, plus ~/.zshenv when zsh is in play (RC_ZSH stays empty otherwise).
# .zshenv rather than .zshrc because zsh reads it for NON-interactive shells too,
# which is the ssh case. ~/.profile is deliberately left alone: bash+zsh are
# covered, and a third entry only risks a duplicate prepend.
#
# Set as globals rather than echoed as lines because $HOME is not covered by
# validate_prefix and a home directory containing whitespace would be
# word-split by a `for rc in $(...)` loop.
RC_BASH=""
RC_ZSH=""
resolve_shell_rcs() {
	home="$1"
	RC_BASH="$home/.bashrc"
	RC_ZSH=""
	case "${SHELL:-}" in
		*zsh) RC_ZSH="$home/.zshenv" ;;
		*)
			if [ -f "$home/.zshrc" ] || [ -f "$home/.zshenv" ]; then
				RC_ZSH="$home/.zshenv"
			fi
			;;
	esac
}

# ensure_path_entry writes the managed PATH block for a USER-MODE install.
# It never runs in sudo mode: a root install editing /root/.bashrc (or
# $SUDO_USER's) would be a surprise, and create_bin_symlinks already covers that
# mode via /usr/local/bin.
#
# An unwritable/symlinked/malformed rc WARNS and never fails the install. The
# binaries are already in place and the printed absolute path still works;
# killing a successful install over a PATH convenience would be the #333 failure
# shape inverted.
ensure_path_entry() {
	prefix="$1"
	if [ "${TMH_INSTALL_NO_SHELL_PATH:-}" = "1" ]; then
		log "TMH_INSTALL_NO_SHELL_PATH=1 — not touching any shell rc file"
		return 0
	fi
	if [ "${TMH_INSTALL_NO_LINK:-}" = "1" ]; then
		log "TMH_INSTALL_NO_LINK=1 — not touching any shell rc file"
		return 0
	fi
	if [ "${TMH_INSTALL_DRYRUN:-}" = "1" ]; then
		log "[dryrun] would prepend the managed PATH block for $prefix/current/bin to the shell rc files"
		return 0
	fi
	home="${HOME:-}"
	if [ -z "$home" ] || [ ! -d "$home" ]; then
		warn "\$HOME is unset or not a directory — PATH was not persisted.
       fix: export PATH=\"$prefix/current/bin:\$PATH\" in your shell startup file."
		return 0
	fi
	resolve_shell_rcs "$home"
	for rc in "$RC_BASH" "$RC_ZSH"; do
		[ -n "$rc" ] || continue
		if rewrite_rc "$rc" install "$prefix/current/bin"; then
			PATH_PERSISTED=1
			log "PATH: managed block written to $rc (previous contents backed up to $rc.tmh-bak)"
		fi
	done
	return 0
}

# remove_path_entry strips the managed block back out, leaving the user's own
# content byte-identical. The <rc>.tmh-bak backups are deliberately KEPT and
# named in the output: deleting the user's only pre-edit copy at the exact moment
# a strip could have gone wrong is the wrong instinct, and this function's
# contract is already "preserves things, prints what it kept".
remove_path_entry() {
	prefix="$1"
	home="${HOME:-}"
	[ -n "$home" ] && [ -d "$home" ] || return 0
	resolve_shell_rcs "$home"
	for rc in "$RC_BASH" "$RC_ZSH"; do
		[ -n "$rc" ] || continue
		[ -f "$rc" ] || continue
		if rewrite_rc "$rc" remove "$prefix/current/bin"; then
			log "removed the managed PATH block from $rc"
			if [ -f "$rc.tmh-bak" ]; then
				log "kept the backup $rc.tmh-bak (delete it yourself if you no longer want it)"
			fi
		fi
	done
	return 0
}

# ---------------------------------------------------------------------------
# SoftHSM setup — one idempotent contract shared with brew caveats + guides.
# ---------------------------------------------------------------------------

# install_softhsm installs the softhsm2 package where a supported package
# manager exists (apt on Debian/Ubuntu, brew on macOS), then delegates token
# init to `tmh init-hsm`. When in sudo mode, init-hsm runs as $SUDO_USER, NEVER
# as root, so tokens land in the invoking user's HSM store.
# Failure is a HARD non-zero exit with remediation, UNLESS TMH_INSTALL_NO_HSM=1.
setup_softhsm() {
	prefix="$1"
	os="$2"
	is_sudo="$3"

	if [ "${TMH_INSTALL_NO_HSM:-}" = "1" ]; then
		log "TMH_INSTALL_NO_HSM=1 — skipping SoftHSM setup"
		return 0
	fi

	if [ "${TMH_INSTALL_DRYRUN:-}" = "1" ]; then
		log "[dryrun] would install softhsm2 and run 'tmh init-hsm --env-file $(hsm_env_path "$is_sudo") --pin-file $(hsm_pin_path "$is_sudo")'"
		return 0
	fi

	# 1. Ensure the softhsm2 package is present.
	if command -v softhsm2-util >/dev/null 2>&1; then
		log "softhsm2 already present"
	elif [ "$os" = "linux" ] && command -v apt-get >/dev/null 2>&1; then
		if [ "$is_sudo" = "1" ]; then
			if apt-get update -y >&2 && apt-get install -y softhsm2 >&2; then
				:
			else
				err "failed to install softhsm2 via apt. Remediation: run 'sudo apt install -y softhsm2' then re-run this installer (it resumes cleanly). $README_URL"
			fi
		else
			err "softhsm2 is not installed and installing it needs root.
       Run this exact command, then re-run the installer (it resumes cleanly):
         sudo apt install -y softhsm2
       Or set TMH_INSTALL_NO_HSM=1 to skip HSM setup. $README_URL"
		fi
	elif [ "$os" = "darwin" ] && command -v brew >/dev/null 2>&1; then
		brew install softhsm >&2 ||
			err "failed to install softhsm via brew. Remediation: run 'brew install softhsm' then re-run. $README_URL"
	else
		err "could not find a package manager to install softhsm2 (need apt on Linux or brew on macOS).
       Install softhsm2 manually, then re-run (it resumes cleanly), or set TMH_INSTALL_NO_HSM=1. $README_URL"
	fi

	# 2. Delegate token init to `tmh init-hsm` (idempotent; init-hsm owns the
	#    env-file + pin-file contract). We pass --env-file / --pin-file explicitly
	#    so the config lands in the correct user's ~/.tmh.
	#    Privilege handling:
	#      - sudo mode with a real $SUDO_USER: drop to that user via `su -` so the
	#        SoftHSM tokens and pin belong to the human, not root.
	#      - a genuine root install (uid 0, SUDO_USER unset or root): init-hsm runs
	#        as root and legitimately creates HSM material under /root/.tmh. This
	#        is valid — we do NOT refuse it, but we warn so it isn't a surprise.
	#      - user mode: runs as the current user.
	tmh_bin="$prefix/current/bin/tmh"
	if [ ! -x "$tmh_bin" ]; then
		err "cannot run init-hsm: $tmh_bin not found. $README_URL"
	fi

	hsm_env=$(hsm_env_path "$is_sudo")
	hsm_pin=$(hsm_pin_path "$is_sudo")

	if [ "$is_sudo" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
		log "running 'tmh init-hsm' as $SUDO_USER (not root); env-file=$hsm_env"
		su - "$SUDO_USER" -c "'$tmh_bin' init-hsm --env-file '$hsm_env' --pin-file '$hsm_pin'" >&2 ||
			err "'tmh init-hsm' failed. Fix the reported issue and re-run (idempotent), or set TMH_INSTALL_NO_HSM=1. $README_URL"
	else
		if [ "$is_sudo" = "1" ]; then
			# Genuine root install: no unprivileged user to drop to.
			warn "running as root with no SUDO_USER — HSM material is being created under $hsm_env (root-owned). This is a root install."
		fi
		"$tmh_bin" init-hsm --env-file "$hsm_env" --pin-file "$hsm_pin" >&2 ||
			err "'tmh init-hsm' failed. Fix the reported issue and re-run (idempotent), or set TMH_INSTALL_NO_HSM=1. $README_URL"
	fi
	log "SoftHSM token initialization complete (env-file: $hsm_env)"
}

# invoking_user_home echoes the home directory of the user who will actually own
# the HSM config + tokens. In sudo mode that is $SUDO_USER's home (NEVER root's),
# because `tmh init-hsm` runs as that user; otherwise it is the current $HOME.
# HSM config lives in ~/.tmh regardless of the binary install prefix.
invoking_user_home() {
	is_sudo="$1"
	if [ "$is_sudo" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
		# Resolve $SUDO_USER's home from the passwd database. We deliberately do
		# NOT use `eval ... ~$SUDO_USER`: SUDO_USER is environment-derived and
		# eval on it is a code-injection footgun. getent is the safe lookup.
		if command -v getent >/dev/null 2>&1; then
			getent_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
			if [ -n "$getent_home" ]; then
				printf '%s' "$getent_home"
				return 0
			fi
		fi
		# Fallback when getent is unavailable (e.g. macOS): the conventional path.
		printf '/home/%s' "$SUDO_USER"
		return 0
	fi
	printf '%s' "${HOME:-/root}"
}

# hsm_env_path / hsm_pin_path echo the env-file + pin-file paths init-hsm writes.
# These match Lane A's init-hsm defaults ($HOME/.tmh/hsm.env, $HOME/.tmh/hsm.pin)
# but are passed explicitly so sudo-mode lands them in the real user's home.
hsm_env_path() {
	printf '%s/.tmh/hsm.env' "$(invoking_user_home "$1")"
}

hsm_pin_path() {
	printf '%s/.tmh/hsm.pin' "$(invoking_user_home "$1")"
}

# ---------------------------------------------------------------------------
# Uninstall — removes binaries + symlinks, PRESERVES tokens and config.
# ---------------------------------------------------------------------------

do_uninstall() {
	prefix="$1"
	is_sudo="$2"
	log "uninstalling tmh from $prefix"
	log "NOTE: HSM tokens and configuration are PRESERVED (SoftHSM store + env-file are left untouched)."

	if [ "${TMH_INSTALL_DRYRUN:-}" = "1" ]; then
		log "[dryrun] would remove $prefix/releases and $prefix/current, /usr/local/bin symlinks, and the managed PATH block"
		return 0
	fi

	# Remove /usr/local/bin symlinks that point into our prefix.
	for b in $BINARIES; do
		link="/usr/local/bin/$b"
		if [ -L "$link" ]; then
			tgt=$(readlink "$link" 2>/dev/null || true)
			case "$tgt" in
				"$prefix"/*) rm -f "$link" && log "removed $link" ;;
			esac
		fi
	done

	# Strip the managed PATH block (user mode only — sudo mode never wrote one).
	if [ "$is_sudo" != "1" ]; then
		remove_path_entry "$prefix"
	fi

	# Remove installed binaries but keep tokens/config that live outside these dirs.
	rm -rf "$prefix/releases" "$prefix/current"
	log "removed installed binaries under $prefix"
	log "tokens and config preserved. Uninstall complete."
}

# ---------------------------------------------------------------------------
# Success machine-contract line
# ---------------------------------------------------------------------------

emit_ok() {
	# The ONE stable parseable line. STDOUT only. Must be the last stdout line.
	#
	# version= is the release LABEL (a directory name) — the field an agent uses
	# to compare or to re-pin is binary_version=, which is why both are here.
	# path_persisted= exists because every warning above went to STDERR: without
	# it, a stdout-only parser cannot distinguish successful PATH wiring from a
	# warning-only failure.
	printf 'tmh-install: OK version=%s prefix=%s env_file=%s binary_version=%s release_digest=%s path_persisted=%s\n' \
		"$1" "$2" "$3" "$4" "$5" "$6"
}

# print_next_step <prefix> <is_sudo> <path_persisted>
#
# Branches on what ACTUALLY happened. "New shells are already wired" is a lie
# under TMH_INSTALL_NO_SHELL_PATH=1, under sudo + TMH_INSTALL_NO_LINK=1, and
# whenever an rc rewrite was refused — so those cases print differently. The
# printed command is executable as printed in every mode, which is the universal
# half of the #337 fix and the only half that survives systemd, cron and
# containers.
print_next_step() {
	prefix="$1"
	is_sudo="$2"
	path_persisted="$3"
	bin="$prefix/current/bin"

	if [ -n "${TMH_PORTAL_URL:-}" ]; then
		enroll_args="enroll --portal-url ${TMH_PORTAL_URL%/}"
	else
		enroll_args="enroll --portal-url <your-portal-url>   # replace with your portal, e.g. https://thatsmyhuman.ai"
	fi

	log ""
	log "tmh installed. Binaries: tmh, tmh-broker, mcp-agent (under $bin)."

	if [ "$is_sudo" = "1" ] && [ "${TMH_INSTALL_NO_LINK:-}" != "1" ]; then
		log "Next step — enroll this machine:"
		log "  tmh $enroll_args"
		return 0
	fi

	log "Next step — enroll this machine (this exact command works right now):"
	log "  $bin/tmh $enroll_args"
	log ""
	if [ "$path_persisted" = "1" ]; then
		log "To use the short 'tmh' name in THIS shell:"
		log "  export PATH=\"$bin:\$PATH\""
		log "New shells are already wired up (a managed block was added to your shell rc)."
	else
		log "PATH was NOT persisted. To use the short 'tmh' name in this shell:"
		log "  export PATH=\"$bin:\$PATH\""
		log "Add that line to your shell startup file to make it permanent."
	fi
}

# ---------------------------------------------------------------------------
# main — the ONLY top-level statement is `main "$@"` on the last line.
# ---------------------------------------------------------------------------

main() {
	# Temp dirs and the install lock are released here on success, on err(), and
	# on interruption. Set before anything can create them.
	trap 'cleanup' EXIT
	trap 'cleanup; exit 130' INT
	trap 'cleanup; exit 143' TERM
	trap 'cleanup; exit 129' HUP

	# --- Parse flags -----------------------------------------------------
	action="install"
	for arg in "$@"; do
		case "$arg" in
			--help | -h)
				print_help
				exit 0
				;;
			--uninstall)
				action="uninstall"
				;;
			*)
				err "unknown argument '$arg'. Run with --help for the flag contract. $README_URL"
				;;
		esac
	done

	# --- Resolve mode / prefix ------------------------------------------
	# User-mode ($HOME/.tmh, no sudo) is PRIMARY. Sudo system install secondary.
	uid=$(id -u 2>/dev/null || echo 1000)
	is_sudo="0"
	if [ "$uid" = "0" ]; then
		is_sudo="1"
	fi

	if [ -n "${TMH_INSTALL_PREFIX:-}" ]; then
		prefix="$TMH_INSTALL_PREFIX"
	elif [ "$is_sudo" = "1" ]; then
		prefix="/opt/tmh"
	else
		# Non-root default is user-mode.
		prefix="${HOME:-/root}/.tmh"
	fi

	# Mode for every directory this script creates under the prefix (issue #333).
	# A system install must stay world-READABLE so any user can exec the binaries
	# (0755); a user-mode prefix has no such requirement and gets 0700. Neither
	# grants group or other WRITE, which is the property untrustedComponent
	# requires of every ancestor of ~/.tmh/hsm.env. Deliberately NOT umask-derived:
	# inheriting the umask is the bug.
	if [ "$is_sudo" = "1" ]; then
		dir_mode="0755"
	else
		dir_mode="0700"
	fi

	# --- Validate untrusted env BEFORE any action, install or uninstall --
	# This block sits above the uninstall short-circuit on purpose: do_uninstall
	# runs `rm -rf "$prefix/releases"`, and it used to do so on a prefix nothing
	# had ever checked.
	validate_version
	validate_prefix "$prefix"

	# --- Uninstall short-circuit ----------------------------------------
	if [ "$action" = "uninstall" ]; then
		do_uninstall "$prefix" "$is_sudo"
		exit 0
	fi

	validate_base_url

	# --- Preflight: OS / arch / libc ------------------------------------
	os=$(detect_os)
	arch=$(detect_arch)
	check_libc "$os"
	log "target: $os/$arch  prefix: $prefix  mode: $([ "$is_sudo" = 1 ] && echo sudo || echo user)"

	# --- Non-TTY guard: never prompt; fail fast with exact handoff ------
	# A system install needs root. If we're not root, not user-mode-prefixed,
	# and can't prompt (piped), tell the caller exactly what to run.
	if [ "$is_sudo" != "1" ] && [ -z "${TMH_INSTALL_PREFIX:-}" ] && ! is_tty; then
		# We *default* to user-mode here (prefix already = $HOME/.tmh), which is
		# fine and needs no root — but be explicit so agents/humans know the
		# two supported handoffs.
		log "running in user-mode (no sudo). Installing to $prefix."
		log "For a system-wide install instead, re-run as:"
		log "  curl -fsSL <url>/install.sh | sudo sh"
	fi

	# --- Resolve download URLs ------------------------------------------
	base_url=$(resolve_base_url)
	# The asset filename is VERSION-LESS and identical for both the "latest"
	# redirect and the pinned-version download path. GitHub's
	# releases/latest/download/<asset> redirect resolves to the literal filename,
	# so the name must be stable across releases. The release workflow publishes
	# exactly one file per target under this name; SHA256SUMS references it too.
	asset="tmh_${os}_${arch}.tar.gz"
	tarball_url="$base_url/$asset"
	sums_url="$base_url/SHA256SUMS"
	sig_url="$base_url/SHA256SUMS.minisig"

	# --- Download into a temp workdir -----------------------------------
	workdir=$(mktemp -d 2>/dev/null || mktemp -d -t tmhinstall.XXXXXX)
	CLEANUP_WORKDIR="$workdir"
	tarball="$workdir/$asset"
	sums="$workdir/SHA256SUMS"
	sig="$workdir/SHA256SUMS.minisig"

	log "downloading $asset ..."
	if ! http_get "$tarball_url" "$tarball"; then
		# Distinguish rate-limit from generic failure where curl surfaced it.
		if [ -n "${TMH_INSTALL_VERSION:-}" ]; then
			pin_hint="$TMH_INSTALL_VERSION is already pinned — check that the tag exists at $RELEASES_URL"
		else
			pin_hint="pin a published tag from $RELEASES_URL (e.g. v0.1.0):
         curl -fsSL <url>/install.sh | TMH_INSTALL_VERSION=v0.1.0 sh"
		fi
		err "download failed: $tarball_url
       If you hit a GitHub rate limit (HTTP 403/429), $pin_hint
       The assignment must bind to sh, not curl.
       Otherwise check connectivity and retry. $README_URL"
	fi

	log "downloading SHA256SUMS ..."
	http_get "$sums_url" "$sums" ||
		err "failed to download SHA256SUMS: $sums_url — cannot verify integrity, aborting. $README_URL"

	# Signature file is best-effort to download; absence is handled in verify.
	log "downloading SHA256SUMS.minisig ..."
	if ! http_get "$sig_url" "$sig"; then
		warn "could not download SHA256SUMS.minisig; signature verification may be skipped."
		rm -f "$sig"
	fi

	# --- Verify (checksum ALWAYS, signature when available/required) ----
	verify_checksum "$tarball" "$sums" "$asset"
	if [ -f "$sig" ]; then
		verify_signature "$sums" "$sig"
	else
		# No sig file present: reuse the absent-minisign policy (respects
		# TMH_INSTALL_REQUIRE_SIGNATURE=1).
		if [ "${TMH_INSTALL_REQUIRE_SIGNATURE:-}" = "1" ]; then
			err "SHA256SUMS.minisig unavailable but TMH_INSTALL_REQUIRE_SIGNATURE=1 (fail-closed). $README_URL"
		fi
		warn "no signature file — checksum-only verification."
	fi

	# --- Install (staging -> release -> atomic flip) --------------------
	# The label is resolved INSIDE install_release, from the pin, the verified
	# binary, or the tarball digest — in that order (issue #336).
	install_release "$prefix" "${TMH_INSTALL_VERSION:-}" "$tarball" "$dir_mode"

	# --- Make the binaries reachable ------------------------------------
	if [ "$is_sudo" = "1" ]; then
		create_bin_symlinks "$prefix"
	else
		ensure_path_entry "$prefix"
	fi

	# --- SoftHSM setup (shared idempotent contract) ---------------------
	setup_softhsm "$prefix" "$os" "$is_sudo"

	# --- Cleanup + machine contract -------------------------------------
	cleanup
	# The env-file lives in the invoking user's ~/.tmh (see hsm_env_path), not
	# under the binary install prefix — init-hsm runs as that user.
	env_file=$(hsm_env_path "$is_sudo")

	print_next_step "$prefix" "$is_sudo" "$PATH_PERSISTED" # human summary -> STDERR
	emit_ok "$INSTALLED_VERSION" "$prefix" "$env_file" \
		"$BINARY_VERSION" "$RELEASE_DIGEST" "$PATH_PERSISTED" # machine line -> STDOUT (last)
}

main "$@"
