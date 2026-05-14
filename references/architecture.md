# Agent VPN Architecture (nvpn-client 0.9.x)

## Components

- **`/usr/bin/nvpn-client`** — Statically-linked Go binary (Norton's `nvpn-client`, shipped as `nvpn-client_0.9.0-beta1_amd64.deb` and unpacked into the Alpine image without dpkg — see `references/upgrading-nvpn-client.md`). Owns:
  - Authentication against Elysium (`/elysium/v1/token` under `VPN_SERVICE_BASE_URL`).
  - Server discovery (`--locations`).
  - WireGuard config generation: writes `/etc/wireguard/wg0.conf` from the server's `discover` response.
  - Logging to `/var/log/nvpn-client/nvpn-client.log`.
  - **Does NOT bring up `wg0` itself** — that's the entrypoint's job (so we can sequence the SOCKS5 proxy correctly).
- **`/usr/bin/wireguard-go`** — Userspace WireGuard implementation (built from `git.zx2c4.com/wireguard-go`). Required because the kernel WireGuard module isn't available in the container. `wg-quick` auto-detects it.
- **`/usr/bin/microsocks`** — Tiny SOCKS5 proxy (built from `github.com/rofl0r/microsocks`), launched on `0.0.0.0:1080` *inside* the container by the entrypoint, **after** `wg-quick up wg0` succeeds.
- **`/usr/local/bin/docker-entrypoint.sh`** — Owns container lifecycle: env→config patching, `nvpn-client --connect`, `wg-quick up`, DNS fixup, microsocks launch, health-check + reconnect loop, signal-trap teardown.
- **`/usr/local/bin/pi-scan.sh`** — Two-tier prompt injection scanner invoked by the `safefetch` entrypoint command. Tier 1: heuristic regex matching against `/usr/local/share/pi-patterns.txt`. Tier 2: ML inference via `pi-ml-scan`.
- **`/usr/local/bin/pi-ml-scan`** — Static Rust binary embedding a BERT-based PI model (6 layers, hidden=384, 12 heads, INT8 ONNX, ~22 MB). Built with `tract-onnx` (pure Rust, no C dependencies). Uses 512-token sliding-window chunking with 128-token overlap for long content. Classifies text as safe/injection via softmax over 2-class logits; block threshold 0.99. Invoked by `pi-scan.sh` when heuristic scan passes.
- **WireGuard interface**: `wg0` (single interface per container).

The Norton-shipped `/lib/systemd/system/nvpn-client.service` and `/usr/bin/nvpn-client-daemon` are present in the image but unused — the container manages its own lifecycle, and a 1-line bash sleep loop is not enough (it never brings up `wg0`).

## Required Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `UDID` | — (required) | Agent VPN-provisioned, format `U1.<uuid>.<region>.<64-hex>`. The UDID alone is sufficient for auth in 0.9.x — Elysium derives the client identity from it. |
| `VPN_LOCATION` | `Palo Alto` (entrypoint default) | city name (e.g. `Tokyo`) or location key (e.g. `JP-40-TOKYO`); auto-detected by shape |
| `VPN_LOCATION_FORMAT` | auto-detected | optional override: `city` or `location-key` |
| `ELYSIUM_AUTH_CLIENT_NAME` | `sprinkler` (compiled in) | optional override |
| `VPN_SERVICE_BASE_URL` | `https://api.se-platform.com` (compiled in) | optional override |
| `ELYSIUM_AUTH_CLIENT_KEY` | unset | **Legacy.** No longer required; if provided and stale/wrong, Elysium returns 401. |
| `ELYSIUM_CERT_PINS` | unset | optional, comma-separated SHA-256 fingerprints |
| `DISCOVERY_CERT_PINS` | unset | optional, same format |

### Daemon-mode tunables (entrypoint-level)

| Variable | Default | Notes |
|---|---|---|
| `HEALTH_INTERVAL` | `60` (seconds) | how often the entrypoint runs `wg show wg0 transfer` after the tunnel is up |
| `RECONNECT_BACKOFF_INITIAL` | `10` (seconds) | base for exponential backoff between reconnect attempts |
| `RECONNECT_BACKOFF_MAX` | `300` (seconds) | cap on the backoff |
| `MAX_INITIAL_CONNECT_ATTEMPTS` | `10` | fail-fast cap. After this many consecutive failed first-time connects, the entrypoint exits non-zero so the container shows `Exited(1)` instead of silently retrying forever. Once at least one connect has succeeded, the steady-state loop retries indefinitely. |
| `SAFEFETCH_TIMEOUT` | `30` (seconds) | curl timeout for `safefetch` command |
| `PI_ML_ENABLED` | `1` | set to `0` to skip ML tier in PI scanning (heuristic-only mode) |

## Auth + Tunnel Flow

1. Entrypoint patches `/etc/nvpn-client/config` with any `-e` overrides so a manual `nvpn-client` invocation inside the container sees the same values.
2. Entrypoint runs `nvpn-client --env-file=/etc/nvpn-client/config --connect --location=<loc>`:
    1. `nvpn-client` POSTs to `${VPN_SERVICE_BASE_URL}/elysium/v1/token` with `ELYSIUM_AUTH_CLIENT_NAME` + `UDID` (and optionally `ELYSIUM_AUTH_CLIENT_KEY` if set, but it's no longer required as of 0.9.x). Receives an access token.
    2. Calls `${VPN_SERVICE_BASE_URL}/discovery/v9/discover?protocol=...` to get a tunnel assignment for the requested location: peer pubkey, endpoint, allowed-IPs, client IP, DNS, etc.
    3. Writes `/etc/wireguard/wg0.conf`.
3. Entrypoint strips the `DNS = ...` directive (Alpine has no `resolvconf` and `wg-quick` would fail), then runs `wg-quick up wg0`. `wg-quick` detects `wireguard-go` in `$PATH` and uses it instead of a kernel module.
4. Entrypoint writes `nameserver <dns>` to `/etc/resolv.conf` directly.
5. Entrypoint launches `microsocks` on `0.0.0.0:1080` inside the container — strictly *after* the tunnel is up so SOCKS5 traffic can never egress via the host network.
6. Entrypoint touches `/var/run/vpn-up` as a "tunnel ready" flag. Recipes can use `docker exec <name> test -e /var/run/vpn-up` to fail fast before issuing requests through the container; this prevents accidental host-network egress when the tunnel is down.
7. Entrypoint enters a health-check loop (`wg show wg0 transfer` every `HEALTH_INTERVAL` seconds); on failure it removes the flag, tears down `wg0`, and reconnects with exponential backoff (`RECONNECT_BACKOFF_INITIAL` → `RECONNECT_BACKOFF_MAX`).

## Container Requirements

- `--cap-add=NET_ADMIN` — required for creating the wg0 interface and managing routes.
- `--device=/dev/net/tun` — required for the TUN device used by `wireguard-go`.
- The Dockerfile includes a `sysctl` wrapper that tolerates permission errors in unprivileged containers.
