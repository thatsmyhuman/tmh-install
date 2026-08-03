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

# Minimum supported glibc. Debian 12+, Ubuntu 22.04+, RHEL 9+.
MIN_GLIBC_MAJOR="2"
MIN_GLIBC_MINOR="35"

# Pinned minisign public key. The operator REPLACES this placeholder with the
# real release-signing pubkey at release time. The same key is additionally
# published at {portal}/minisign.pub for out-of-band verification.
# minisign public keys start with "RW".
MINISIGN_PUBLIC_KEY="RWRuUhkMimvWU+Xp3zPJLvzFwmCuLenHg4WB5xNtNMqGF4+LsiK7Upgc"

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
  --uninstall    Remove installed binaries and symlinks. PRESERVES HSM tokens
                 and configuration (env-file, SoftHSM tokens). Prints what it kept.

ENVIRONMENT VARIABLES:
  TMH_INSTALL_VERSION         Pin a release, e.g. v0.1.0. Default: latest redirect.
                              Use to roll back or to work around a 403/429 rate limit.
  TMH_INSTALL_PREFIX          Install prefix. Default /opt/tmh (system) — set to
                              "$HOME/.tmh" for user-mode (no sudo). User-mode is PRIMARY.
  TMH_INSTALL_BASE_URL        Override download origin (mirror / air-gap). Replaces the
                              default GitHub Releases origin.
  TMH_INSTALL_NO_LINK=1       Do not create /usr/local/bin symlinks (sudo mode only).
  TMH_INSTALL_NO_HSM=1        Skip SoftHSM package install + token init entirely.
  TMH_INSTALL_REQUIRE_SIGNATURE=1
                              Fail closed if minisign is unavailable (no checksum-only fallback).
  TMH_INSTALL_DRYRUN=1        Do everything EXCEPT mutating system dirs / running package
                              managers. Exercises arch map, URL construction, checksum,
                              and symlink-flip logic in a temp prefix. For CI.
  TMH_PORTAL_URL              Portal base URL. Used to render the exact next-step command
                              on success. When unset, a generic next-step message is shown.

MACHINE CONTRACT:
  On success, the LAST line of STDOUT is exactly:
    tmh-install: OK version=<ver> prefix=<prefix> env_file=<path>
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

# validate_version rejects a TMH_INSTALL_VERSION containing anything outside
# [A-Za-z0-9._-]. The value flows into path components (mkdir, rm -rf, ln -s),
# so a value like "../evil" or one with a slash/space must never be accepted.
validate_version() {
	[ -n "${TMH_INSTALL_VERSION:-}" ] || return 0
	# POSIX grep -E; anchor the whole string. No shell glob/case pitfalls.
	if ! printf '%s' "$TMH_INSTALL_VERSION" | grep -Eq '^[A-Za-z0-9._-]+$'; then
		err "invalid TMH_INSTALL_VERSION '$TMH_INSTALL_VERSION' — allowed characters are A-Z a-z 0-9 . _ - only. $README_URL"
	fi
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

# install_release performs the trust-critical placement:
#   1. Unpack the verified tarball into an immutable staging dir.
#   2. Validate all three binaries.
#   3. Move into <prefix>/releases/<version>/.
#   4. Atomically flip the <prefix>/current symlink (ln -s to a temp name, then
#      mv -f over the old symlink — mv of a symlink is atomic on POSIX, so a
#      concurrent reader never sees a missing 'current').
# Same-version re-run: compare-and-no-op; never mutate the live dir.
install_release() {
	prefix="$1"
	version="$2"
	tarball="$3"

	releases_dir="$prefix/releases"
	target_dir="$releases_dir/$version"
	current_link="$prefix/current"

	if [ "${TMH_INSTALL_DRYRUN:-}" = "1" ]; then
		# DRYRUN: exercise the unpack + validation + symlink-flip logic entirely
		# inside a throwaway temp prefix; never touch the real system dirs.
		dry_prefix=$(mktemp -d 2>/dev/null || mktemp -d -t tmhinstall.XXXXXX)
		log "[dryrun] using temp prefix $dry_prefix (real prefix would be $prefix)"
		dry_releases="$dry_prefix/releases"
		dry_target="$dry_releases/$version"
		mkdir -p "$dry_target"
		tar -xzf "$tarball" -C "$dry_target"
		flatten_if_nested "$dry_target"
		validate_binaries "$dry_target"
		# Simulate the atomic flip in the temp prefix.
		ln -s "releases/$version" "$dry_prefix/current.tmp.$$"
		rm -f "$dry_prefix/current"
		mv -f "$dry_prefix/current.tmp.$$" "$dry_prefix/current"
		log "[dryrun] symlink flip OK: $dry_prefix/current -> releases/$version"
		rm -rf "$dry_prefix"
		return 0
	fi

	# Same-version no-op guard: if the release dir already exists and contains a
	# valid binary set, do not mutate it. Just (re-)point current at it. Binaries
	# live under <target>/bin/ (the bin/ layout), so check that real path.
	if [ -x "$target_dir/bin/tmh" ] && [ -x "$target_dir/bin/tmh-broker" ] && [ -x "$target_dir/bin/mcp-agent" ]; then
		log "version $version already installed at $target_dir — comparing, not overwriting"
		if [ -L "$current_link" ] && [ "$(readlink "$current_link" 2>/dev/null)" = "releases/$version" ]; then
			log "current already points at $version — no-op"
			return 0
		fi
		# Re-point current without touching the immutable release dir.
		# rm the old symlink first: `mv -f newlink current` FOLLOWS an existing
		# symlink-to-directory and moves newlink INTO it (leaving current stale)
		# on both GNU and BSD. rm removes only the link (never follows), so the
		# subsequent mv creates a fresh symlink. Tiny non-atomic window is
		# acceptable at install time.
		ln -s "releases/$version" "$current_link.tmp.$$"
		rm -f "$current_link"
		mv -f "$current_link.tmp.$$" "$current_link"
		log "re-pointed current -> releases/$version"
		return 0
	fi

	# Fresh install. Unpack into an immutable staging dir first so a failed
	# unpack never leaves a half-populated release dir under 'current'.
	staging=$(mktemp -d 2>/dev/null || mktemp -d -t tmhinstall.XXXXXX)
	tar -xzf "$tarball" -C "$staging" ||
		err "failed to unpack $tarball. $README_URL"
	flatten_if_nested "$staging"
	validate_binaries "$staging"

	# Lay out <target>/bin/<binary> so 'current/bin' is a clean PATH entry.
	mkdir -p "$releases_dir"
	rm -rf "$target_dir"
	mkdir -p "$target_dir/bin"
	for b in $BINARIES; do
		mv "$staging/$b" "$target_dir/bin/$b"
	done
	rm -rf "$staging"

	# SYMLINK FLIP. Create a uniquely-named temp symlink, rm any existing
	# 'current', then mv the temp symlink into place. The rm is required: on an
	# UPGRADE, 'current' is a symlink to the previous release DIRECTORY, and
	# `mv -f newlink current` FOLLOWS it and moves newlink INTO that directory
	# (leaving 'current' pointing at the old release) on both GNU and BSD mv.
	# rm removes only the link (rm never follows a symlink), so mv then creates
	# a fresh 'current'. The rm→mv window is microscopic and install-time only.
	ln -s "releases/$version" "$current_link.tmp.$$"
	rm -f "$current_link"
	mv -f "$current_link.tmp.$$" "$current_link"
	log "installed $version -> $target_dir; current -> releases/$version"
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
	log "uninstalling tmh from $prefix"
	log "NOTE: HSM tokens and configuration are PRESERVED (SoftHSM store + env-file are left untouched)."

	if [ "${TMH_INSTALL_DRYRUN:-}" = "1" ]; then
		log "[dryrun] would remove $prefix/releases and $prefix/current and /usr/local/bin symlinks"
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
	version="$1"
	prefix="$2"
	env_file="$3"
	printf 'tmh-install: OK version=%s prefix=%s env_file=%s\n' "$version" "$prefix" "$env_file"
}

print_next_step() {
	# Human-facing next command -> STDERR only. Uses TMH_PORTAL_URL when set.
	prefix="$1"
	log ""
	log "tmh installed. Binaries: tmh, tmh-broker, mcp-agent (under $prefix/current/bin)."
	if [ -n "${TMH_PORTAL_URL:-}" ]; then
		log "Next step — enroll this machine:"
		log "  tmh enroll --portal-url ${TMH_PORTAL_URL%/}"
	else
		log "Next step — enroll this machine against your portal:"
		log "  tmh enroll --portal-url <your-portal-url>"
	fi
}

# ---------------------------------------------------------------------------
# main — the ONLY top-level statement is `main "$@"` on the last line.
# ---------------------------------------------------------------------------

main() {
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

	# --- Uninstall short-circuit ----------------------------------------
	if [ "$action" = "uninstall" ]; then
		do_uninstall "$prefix"
		exit 0
	fi

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

	# --- Validate untrusted env before it flows into paths / transport --
	validate_version
	validate_base_url

	# --- Resolve download URLs ------------------------------------------
	base_url=$(resolve_base_url)
	# The asset version label: pinned value, else "latest" for the redirect path.
	ver_label="${TMH_INSTALL_VERSION:-latest}"
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
	tarball="$workdir/$asset"
	sums="$workdir/SHA256SUMS"
	sig="$workdir/SHA256SUMS.minisig"

	log "downloading $asset ..."
	if ! http_get "$tarball_url" "$tarball"; then
		# Distinguish rate-limit from generic failure where curl surfaced it.
		err "download failed: $tarball_url
       If you hit a GitHub rate limit (HTTP 403/429), pin a version to bypass it
       (the assignment must bind to sh, not curl):
         curl -fsSL <url>/install.sh | TMH_INSTALL_VERSION=$ver_label sh
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

	# --- Determine the concrete installed version label -----------------
	# For pinned installs the label is exact. For 'latest' we record 'latest'
	# unless we can read a VERSION file bundled in the tarball; keep it simple.
	install_version="$ver_label"

	# --- Install (staging -> release -> atomic flip) --------------------
	install_release "$prefix" "$install_version" "$tarball"

	# --- Symlinks (sudo mode) -------------------------------------------
	if [ "$is_sudo" = "1" ]; then
		create_bin_symlinks "$prefix"
	fi

	# --- SoftHSM setup (shared idempotent contract) ---------------------
	setup_softhsm "$prefix" "$os" "$is_sudo"

	# --- Cleanup + machine contract -------------------------------------
	rm -rf "$workdir"
	# The env-file lives in the invoking user's ~/.tmh (see hsm_env_path), not
	# under the binary install prefix — init-hsm runs as that user.
	env_file=$(hsm_env_path "$is_sudo")

	print_next_step "$prefix"          # human summary -> STDERR
	emit_ok "$install_version" "$prefix" "$env_file"  # machine line -> STDOUT (last)
}

main "$@"
