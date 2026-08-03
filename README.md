# tmh-install

Official installer and signed release distribution for the **thatsmyhuman** CLI
suite: `tmh`, `tmh-broker`, and `mcp-agent`.

This repository is a **public mirror** of the install script plus the
[GitHub Releases](https://github.com/thatsmyhuman/tmh-install/releases) that host
the signed binaries. The product source lives in a private repository; only the
installer wrapper and release artifacts are published here.

> **Licensing.** The installer wrapper (`install.sh`) is **MIT-licensed**. The
> downloaded binaries (`tmh`, `tmh-broker`, `mcp-agent`) are **proprietary** and
> are covered by their own license — installing them constitutes acceptance of
> that license.

## Install

### User-mode (primary — no root required)

```sh
curl -fsSL \
  https://github.com/thatsmyhuman/tmh-install/releases/latest/download/install.sh \
  | TMH_INSTALL_PREFIX="$HOME/.tmh" sh
```

The environment assignment must bind to `sh` (not `curl`), so it goes on the
`sh` side of the pipe.

Add `$HOME/.tmh/current/bin` to your `PATH`.

### System-wide (secondary — requires root)

```sh
curl -fsSL \
  https://github.com/thatsmyhuman/tmh-install/releases/latest/download/install.sh | sudo sh
```

This installs into `/opt/tmh` and links `tmh`, `tmh-broker`, `mcp-agent` into
`/usr/local/bin`.

### macOS via Homebrew

```sh
brew install thatsmyhuman/tmh/tmh
```

See [`thatsmyhuman/homebrew-tmh`](https://github.com/thatsmyhuman/homebrew-tmh).

### Discover the full contract

```sh
curl -fsSL <url>/install.sh | sh -s -- --help
```

## After installing

Initialize the SoftHSM token store (idempotent), then enroll:

```sh
tmh init-hsm
tmh enroll --portal-url <your-portal-url>
```

The installer performs `tmh init-hsm` for you when a package manager is
available; it is safe to re-run.

HSM configuration always lands in the invoking user's home, independent of the
binary install prefix (in `sudo` mode this is `$SUDO_USER`'s home, since
`init-hsm` runs as that user — never root):

- `~/.tmh/hsm.env` — exports `SOFTHSM2_CONF`, `PKCS11_MODULE`, `TMH_HSM_PIN_FILE`,
  `TMH_HSM_TOKEN_LABEL`. Source it (or have your shell profile source it) before
  running `tmh`.
- `~/.tmh/hsm.pin` — the token PIN file referenced by `TMH_HSM_PIN_FILE`.

On success the installer prints `env_file=~/.tmh/hsm.env` in its machine-readable
`tmh-install: OK ...` line.

## Verifying releases

Every release ships (asset names are **version-less** so the
`releases/latest/download/<asset>` redirect resolves to a stable filename):

- `tmh_<os>_<arch>.tar.gz` — the binary tarball, e.g. `tmh_linux_amd64.tar.gz`,
  `tmh_darwin_arm64.tar.gz`
- `SHA256SUMS` — checksums for all artifacts (references the version-less names)
- `SHA256SUMS.minisig` — a [minisign](https://jedisct1.github.io/minisign/)
  signature over `SHA256SUMS`

Download URLs for a target:

- latest: `https://github.com/thatsmyhuman/tmh-install/releases/latest/download/tmh_<os>_<arch>.tar.gz`
- pinned: `https://github.com/thatsmyhuman/tmh-install/releases/download/<version>/tmh_<os>_<arch>.tar.gz`

The installer **always** verifies the tarball checksum against `SHA256SUMS`, and
verifies the minisign signature whenever `minisign` is installed. To require the
signature (fail-closed), set `TMH_INSTALL_REQUIRE_SIGNATURE=1`.

### Pinned minisign public key

Verification uses this pinned key. It is embedded in `install.sh` and additionally
published at `{portal}/minisign.pub` for out-of-band confirmation.

```
untrusted comment: thatsmyhuman release signing key
RWRuUhkMimvWU+Xp3zPJLvzFwmCuLenHg4WB5xNtNMqGF4+LsiK7Upgc
```


Manual verification:

```sh
minisign -Vm SHA256SUMS -P "$(cat minisign.pub)"
sha256sum -c SHA256SUMS --ignore-missing
```

### Provenance

Each release tag corresponds to a specific commit in the private product
repository. The tag message records the source commit that produced the
artifacts, so a published release is traceable to the exact build input.

## Supported platforms

| OS     | Arch          |
|--------|---------------|
| Linux  | amd64, arm64  |
| macOS  | amd64, arm64  |

**Minimum glibc 2.35** — Debian 12+, Ubuntu 22.04+, RHEL 9+.

Alpine / musl is **not supported** (the binaries are glibc-linked). See the
container recipe below.

## Rolling back / pinning a version

To install a specific release (or roll back), pin the version (the assignment
must bind to `sh`, not `curl`):

```sh
curl -fsSL \
  https://github.com/thatsmyhuman/tmh-install/releases/latest/download/install.sh \
  | TMH_INSTALL_VERSION=v0.1.0 sh
```

## Environment variables

| Variable | Purpose |
|----------|---------|
| `TMH_INSTALL_VERSION` | Pin a release (e.g. `v0.1.0`); default is the `latest` redirect. Also the rate-limit workaround. |
| `TMH_INSTALL_PREFIX` | Install prefix. Default `/opt/tmh` (system); set to `$HOME/.tmh` for user-mode. |
| `TMH_INSTALL_BASE_URL` | Override the download origin (mirror / air-gap). |
| `TMH_INSTALL_NO_LINK=1` | Skip `/usr/local/bin` symlinks (sudo mode). |
| `TMH_INSTALL_NO_HSM=1` | Skip SoftHSM package install + token init. |
| `TMH_INSTALL_REQUIRE_SIGNATURE=1` | Fail if `minisign` is unavailable (no checksum-only fallback). |
| `TMH_INSTALL_DRYRUN=1` | Do everything except mutating system dirs / package managers (CI). |
| `TMH_PORTAL_URL` | Portal base URL; used to render the exact next-step command. |

## Uninstall

```sh
curl -fsSL \
  https://github.com/thatsmyhuman/tmh-install/releases/latest/download/install.sh | sh -s -- --uninstall
```

Uninstall removes the installed binaries and symlinks but **preserves** your
SoftHSM tokens and configuration.

## Troubleshooting

### Checksum mismatch

The installer aborts before installing anything and prints the expected vs.
actual digest. This means the download was corrupted or tampered with. Retry the
download; if it persists, do **not** run the file — report it.

### `musl` / Alpine detected

The binaries are glibc-linked and will not run on Alpine. Run `tmh` inside a
glibc container. Fetch the version-less tarball for your target and unpack it:

```dockerfile
FROM debian:12
RUN apt-get update && apt-get install -y softhsm2 ca-certificates curl \
 && curl -fsSL \
      https://github.com/thatsmyhuman/tmh-install/releases/latest/download/tmh_linux_amd64.tar.gz \
    | tar -xz -C /usr/local/bin --strip-components=1
```

(Use `tmh_linux_arm64.tar.gz` on arm64. `--strip-components=1` accounts for a
top-level directory in the tarball.) `softhsm2` is required for the token store.

If you build tmh in one stage and copy it into a `debian:12` runtime stage, the
equivalent is `COPY --from=<stage> /opt/tmh/current/bin/ /usr/local/bin/`.

### Rate limit (HTTP 403 / 429)

The default install uses the API-free `latest` redirect, which avoids the
anonymous GitHub API rate limit. If you still hit a limit, pin a version (the
assignment must bind to `sh`, not `curl`):

```sh
curl -fsSL \
  https://github.com/thatsmyhuman/tmh-install/releases/latest/download/install.sh \
  | TMH_INSTALL_VERSION=v0.1.0 sh
```

### Missing sudo

For a system-wide install you need root. Either re-run with `sudo sh`, or use
user-mode:

```sh
curl -fsSL \
  https://github.com/thatsmyhuman/tmh-install/releases/latest/download/install.sh \
  | TMH_INSTALL_PREFIX="$HOME/.tmh" sh
```

## No telemetry

The installer performs **no** telemetry and **no** phone-home of any kind.
