# Upgrading the bundled `nvpn-client` deb

The Dockerfile installs `nvpn-client_<NVPN_DEB_VERSION>_amd64.deb` from `data/debs/` at build time. The current bundled version is set by the `NVPN_DEB_VERSION` ARG at the top of the Dockerfile.

Both architectures are committed for convenience even though only `amd64` is consumed by the Dockerfile today (the host this skill targets is amd64). To build for arm64, change the Dockerfile to copy the arm64 deb and build on an arm64 host or with `docker buildx`.

## Files

```
data/debs/nvpn-client_0.9.0-beta1_amd64.deb     # statically linked Go, used by Dockerfile
data/debs/nvpn-client_0.9.0-beta1_arm64.deb     # dynamically linked Go (needs glibc); not currently consumed
```

## Upgrade procedure

1. Replace the file(s) in `data/debs/` with the new version.
2. Bump `ARG NVPN_DEB_VERSION=` in `Dockerfile` to match.
3. `docker build -t agentvpn .`
4. Smoke test: `docker run --rm -e UDID="$AGENTVPN_UDID" agentvpn locations` — should print a list of cities.

## What's in the deb (for reference)

Each deb contains:

- `/usr/bin/nvpn-client` — main Go binary
- `/usr/bin/nvpn-client-daemon` — small bash wrapper (unused by this skill — `docker-entrypoint.sh` replaces it)
- `/usr/bin/nvpn-mcp-server` — MCP server for AI assistant integration (also unused at the moment)
- `/lib/systemd/system/nvpn-client.service` — systemd unit (irrelevant inside a container)

The deb's `Depends:` (`wireguard (>= 1.0), iproute2, iptables, curl, dnsutils`) are not enforced because we don't use `dpkg`. Instead, the Dockerfile installs the Alpine equivalents (`wireguard-tools`, `iproute2`, `iptables`, `curl`, `bind-tools`) via `apk` and unpacks the deb's payload manually:

```dockerfile
ar x nvpn-client.deb              # extract control.tar.zst + data.tar.zst
unzstd data.tar.zst -o data.tar
tar -xf data.tar -C /             # files land at /usr/bin/, /etc/nvpn-client/
```

This works on Alpine (musl libc) because the **amd64 `nvpn-client` is statically-linked Go** — no glibc dependency. The arm64 build is dynamically linked and would need `gcompat` to run on Alpine; we don't consume it today.

The deb's `postinst` script is **deliberately not run** — it's tailored for Debian's systemd and would `systemctl daemon-reload` and write a default `/etc/nvpn-client/config`. `docker-entrypoint.sh` and the bundled `config.template` replace both behaviors.

## Compatibility checks before bumping

After replacing the deb, verify the binary's CLI hasn't changed in ways that break `docker-entrypoint.sh`:

```bash
docker run --rm --entrypoint /usr/bin/nvpn-client agentvpn --help
```

Confirm the entrypoint still uses currently-supported flags:

- `--env-file=<path>` (sourced for env vars)
- `--connect --location=<value> --format=city|location-key`
- `--locations [--json] [--format=...]`
- `--logfile=<path>` (entrypoint passes `/dev/stderr`)
- `--loglevel=info|debug|...`

If any of those go away or change semantics, update `docker-entrypoint.sh` accordingly before declaring the upgrade good.
