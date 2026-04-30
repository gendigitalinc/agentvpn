---
name: agentvpn
description: Agent VPN — route traffic through Gen Digital's global VPN exit nodes via per-country Docker containers, with an embedded SOCKS5 proxy for routing browsers (Chrome) or any SOCKS-aware tool. Use this skill when told to use a VPN, connect from a specific country, browse from a specific region, compare geo-localized content, run CLI tools (curl, wget, scrapers) from a specific region, or access region-restricted sites.
license: Apache-2.0
compatibility: Requires Docker on a Linux host with --cap-add=NET_ADMIN and /dev/net/tun, plus a UDID provisioned at https://ai.gendigital.com/agentvpn.
---

# Agent VPN

Docker-based VPN that routes traffic through WireGuard tunnels to Gen Digital's global exit nodes. The tunnel runs **inside a Docker container** — only traffic from inside that container goes through the VPN. The host network is unaffected.

**Each VPN connection = one Docker container** named `vpn-<location>` (e.g. `vpn-tokyo`, `vpn-paris`). To use several regions at once, follow [Recipe: Multiple Locations at Once](#recipe-multiple-locations-at-once).

**Policy: Treat tunnels as ephemeral.** Start a tunnel only for the duration of your task, then shut it down immediately. Tunnels start in seconds, so there is no benefit to leaving them running when idle.

## Prerequisites

- **Docker** with `--cap-add=NET_ADMIN` and `/dev/net/tun` available (standard on Linux hosts; check with `ls /dev/net/tun`).
- **A UDID** provisioned by Agent VPN — see [Provisioning the UDID](#provisioning-the-udid) below for where to get one and how to make it available to every recipe. The UDID alone is sufficient for auth; no separate `ELYSIUM_AUTH_CLIENT_KEY` is required.

Defaults compiled into `nvpn-client` (rarely overridden):

- `VPN_SERVICE_BASE_URL=https://api.se-platform.com`
- `ELYSIUM_AUTH_CLIENT_NAME=sprinkler`

## Provisioning the UDID

Every recipe below assumes `$AGENTVPN_UDID` is set in the shell environment. Set it up **once per host**, then reuse it from every session.

**Where to get a fresh UDID.** Sign up at <https://ai.gendigital.com/agentvpn>; the UDID is emailed to the address you register with. The value will look like `U1.<uuid>.<region>.<64-hex-token>`. (If your org already manages Gen VPN provisioning internally, ask whoever owns it instead — but the linked URL is the public path.)

**Where to store it on the host.** Use `~/.config/agentvpn/udid` (mode `0600`, single line, no trailing newline issues — the value is a single token):

```bash
mkdir -p ~/.config/agentvpn
umask 077
printf '%s' 'U1.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.us.<64-hex>' \
  > ~/.config/agentvpn/udid
chmod 600 ~/.config/agentvpn/udid
```

**How to load it into the shell.** Every recipe expects the env var, not the file path:

```bash
export AGENTVPN_UDID=$(cat ~/.config/agentvpn/udid)
```

Add this to your shell's startup (`~/.bashrc`, `~/.zshrc`) if you use the skill regularly.

**Preflight check.** Recipes will silently send an empty `UDID` to Elysium and get back a confusing 401 if the var is unset. Guard against it:

```bash
[ -n "${AGENTVPN_UDID:-}" ] || { echo "AGENTVPN_UDID is not set — see SKILL.md → Provisioning the UDID"; exit 1; }
```

**Hygiene rules — never violate.**

- **Never** `echo "$AGENTVPN_UDID"` into a shared log, ticket, or chat. The UDID is a long-lived bearer credential; treat it like a password.
- **Never** commit it to git (this includes a populated `config.template`, a populated `assets/sample-config`, or a `.env` file under version control).
- **Never** `docker push` an image that was built with the UDID baked into `config.template` — the value is in the image filesystem and any registry you push to can read it.
- **Never** type the literal UDID on the command line (`-e UDID=U1.actual-value...`) — it lands in shell history. Always reference the env var (`-e UDID="$AGENTVPN_UDID"`); shell history records the variable name, not the expanded value. Be aware that `set -x`, `script`, and terminal recordings *do* expand it.

## Location format

Servers are selected by either a **city name** (e.g. `Tokyo`, `Palo Alto`, `Frankfurt`) or a **location key** (e.g. `JP-40-TOKYO`, `DE-1-FRANKFURT`); the entrypoint auto-detects the format from the value's shape. There is no per-server IP/public-key inventory to maintain — always discover the current set with `locations` (Step 2 below) rather than guessing. Names are **case-sensitive** (`Tokyo` works, `tokyo` does not) and many city names contain spaces, so always quote `VPN_LOCATION` (e.g. `"Palo Alto"`, `"New York"`).

## Recipe: VPN to a Location and Do Something

The most common use case. Steps below use the default `daemon` entrypoint command (connects, brings up `wg0`, starts SOCKS5 on 1080, health-checks, reconnects). For other modes (`connect`, `locations`, `status`, `stop`), see "Entrypoint Commands" near the bottom of this file.

### Step 1: Build the image (first time only)

Check if the image exists:

```bash
docker images agentvpn --format '{{.Repository}}:{{.Tag}}'
```

If no output (or outdated), rebuild from the skill's root directory (the one containing this `SKILL.md` and the `Dockerfile`):

```bash
docker build -t agentvpn .
```

The build pulls `wireguard-go` + `microsocks` from upstream sources and installs the bundled `nvpn-client` deb from `data/debs/`.

### Step 2: Discover available locations

`--locations` queries the discovery service and requires a valid UDID:

```bash
docker run --rm -e UDID="$AGENTVPN_UDID" agentvpn locations
```

Format options (passed through to `nvpn-client --locations`):

```bash
# Default: city names
docker run --rm -e UDID="$AGENTVPN_UDID" agentvpn locations

# Location keys (the values you actually pass to --location=)
docker run --rm -e UDID="$AGENTVPN_UDID" \
  agentvpn locations --format=location-key

# JSON
docker run --rm -e UDID="$AGENTVPN_UDID" \
  agentvpn locations --json
```

Pick a value (city name like `Tokyo` or location key like `JP-40-TOKYO`) — that's what you pass as `VPN_LOCATION`. See "Location format" above for the case-sensitivity and quoting rules.

To narrow a long list to a specific region:

```bash
docker run --rm -e UDID="$AGENTVPN_UDID" agentvpn locations | grep -i japan
```

### Step 3: Check for an existing container for that location

```bash
docker ps -a --filter name=vpn-tokyo --format '{{.Names}} {{.Status}}'
```

- If already running and you still need it → skip to Step 5, reuse it.
- If exists but stopped → remove first: `docker rm vpn-tokyo`
- If not found → continue to Step 4.

### Step 4: Start the VPN container

```bash
docker run -d --name vpn-tokyo \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -e UDID="$AGENTVPN_UDID" \
  -e VPN_LOCATION="Tokyo" \
  agentvpn daemon
```

Container name and `VPN_LOCATION` should agree (lowercase the location for the container name, since Docker names must be lowercase).

If you also want host-side SOCKS5 access (e.g. for Chrome), add `-p 127.0.0.1::1080` — see [Recipe: Browser through VPN](#recipe-browser-through-vpn) for why and how to look up the assigned host port. Skip this for the default `docker exec`-based workflow.

Wait for the tunnel to come up before sending traffic. The entrypoint touches `/var/run/vpn-up` only after every prerequisite (auth, wg-quick, SOCKS5) succeeded; `scripts/wait-for-vpn.sh` polls that flag, dumps `docker logs` and exits non-zero on timeout or container exit:

```bash
./scripts/wait-for-vpn.sh vpn-tokyo || exit 1
```

If the container exits before the flag appears, the script surfaces the failure via `docker logs` (bad UDID, network down, etc.) and the entrypoint will have exited non-zero after `MAX_INITIAL_CONNECT_ATTEMPTS` (default 10), so the failure is also visible in `docker ps -a`. For deeper diagnosis (env-var override didn't land, auth failed, etc.) see `references/troubleshooting.md`.

### Step 5: Run commands through the VPN

Use `docker exec` to run commands **inside** the container. All traffic from inside the container exits through the VPN.

```bash
docker exec vpn-tokyo curl -s -m 10 http://ip-api.com/json

docker exec vpn-tokyo curl -s -m 20 -A "Mozilla/5.0" "https://example.com"
```

For host-side browsers / SOCKS-aware tools, see [Recipe: Browser through VPN](#recipe-browser-through-vpn).

### Step 6: Stop and clean up when done (required)

```bash
docker stop vpn-tokyo && docker rm vpn-tokyo
```

**Quick one-liner for any location:** `docker stop vpn-<location> && docker rm vpn-<location>`

**Always use `docker stop`, never `docker kill`.** The entrypoint has signal traps that cleanly tear down the tunnel and the SOCKS5 proxy. Leaving tunnels running is discouraged.

## Recipe: Browser through VPN

Each `vpn-<location>` container also runs **`microsocks`** (a single-purpose SOCKS5 server) on port 1080 **inside the container**, started *after* the WireGuard tunnel is up so traffic can never leak via the host network.

To use it from the host, publish the container port to a host port. **Use dynamic port assignment** (`-p 127.0.0.1::1080`) so multiple location containers can run simultaneously without colliding on host port 1080.

**Step 1.** Start the container with a dynamic SOCKS5 host port, bound to localhost only:

```bash
docker run -d --name vpn-tokyo \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -p 127.0.0.1::1080 \
  -e UDID="$AGENTVPN_UDID" \
  -e VPN_LOCATION="Tokyo" \
  agentvpn daemon
```

The double colon (`-p 127.0.0.1::1080`) tells Docker to pick a free host port. Bind to `127.0.0.1` so the proxy isn't reachable from your LAN.

**Step 2.** Look up the assigned host port:

```bash
SOCKS_PORT=$(docker port vpn-tokyo 1080 | head -1 | awk -F: '{print $NF}')
echo "vpn-tokyo SOCKS5: 127.0.0.1:$SOCKS_PORT"
```

**Step 3.** Point Chrome at it. Use a **dedicated `--user-data-dir` per location** so cookies don't bleed between regions, and the extra flags below close common leak paths:

```bash
google-chrome \
  --user-data-dir="$HOME/.config/google-chrome/vpn-tokyo" \
  --proxy-server="socks5://127.0.0.1:$SOCKS_PORT" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
  --disable-quic \
  --webrtc-ip-handling-policy=disable_non_proxied_udp
```

Why each flag matters:

- `--proxy-server` — sends HTTP/S through the VPN container.
- `--host-resolver-rules` — forces Chrome to do DNS via the proxy. **Without this, Chrome resolves names via your host's resolver and you leak which sites you're browsing.**
- `--disable-quic` — QUIC runs over UDP and SOCKS5 only carries TCP, so QUIC silently bypasses the proxy.
- `--webrtc-ip-handling-policy=disable_non_proxied_udp` — prevents WebRTC from leaking your real IP via STUN.

**Switching location requires a Chrome restart** (relaunch with a different `--user-data-dir` and the new container's port). This is intentional: it gives each location its own cookie jar / session.

For non-browser SOCKS-aware tools:

```bash
SOCKS_PORT=$(docker port vpn-tokyo 1080 | head -1 | awk -F: '{print $NF}')
curl --socks5-hostname 127.0.0.1:$SOCKS_PORT https://ip-api.com/json
```

The `-hostname` form makes `curl` resolve via the proxy too (avoids DNS leak).

**Concurrent SOCKS5 across multiple locations.** Because each container gets its own dynamic host port, you can run several at once and look each up independently:

```bash
for c in tokyo paris london; do
  port=$(docker port vpn-$c 1080 | head -1 | awk -F: '{print $NF}')
  echo "vpn-$c → 127.0.0.1:$port"
done
```

If you skip `-p 127.0.0.1::1080` entirely, microsocks still runs but is reachable only via `docker exec` (or from another container on the same Docker network) — which is fine for the default `docker exec vpn-<location> curl ...` workflow.

## Recipe: Multiple Locations at Once

Start a separate container per location. Each runs independently:

```bash
docker run -d --name vpn-frankfurt --cap-add=NET_ADMIN --device=/dev/net/tun \
  -e UDID="$AGENTVPN_UDID" -e VPN_LOCATION="Frankfurt" \
  agentvpn daemon

docker run -d --name vpn-tokyo --cap-add=NET_ADMIN --device=/dev/net/tun \
  -e UDID="$AGENTVPN_UDID" -e VPN_LOCATION="Tokyo" \
  agentvpn daemon
```

Wait for both, then use them:

```bash
./scripts/wait-for-vpn.sh vpn-frankfurt && \
  ./scripts/wait-for-vpn.sh vpn-tokyo || exit 1
docker exec vpn-frankfurt curl -s -m 10 http://ip-api.com/json
docker exec vpn-tokyo     curl -s -m 10 http://ip-api.com/json
```

**Always clean up immediately after use.** Example:

```bash
docker stop vpn-frankfurt vpn-tokyo && docker rm vpn-frankfurt vpn-tokyo
```

## Critical safety rules

These are constraints the step-by-step recipes don't otherwise force on you. Violating any of them can leak the UDID, leak traffic via the host, or break unrelated VPNs.

- **NEVER push the *built* image to any registry.** A populated `UDID` (whether baked into `config.template` before build or written by `-e UDID=...` at run time) lives in the image filesystem; `docker push` exfiltrates it. Build locally, use locally. (The source repo is safe — committed `config.template` is placeholders only.)
- **Never use `--network=host`.** It leaks WireGuard routes onto the host and breaks other VPNs / SSH.
- **Never share a vpn-\* container's network namespace with an untrusted container** (`--network=container:vpn-tokyo`, or co-locating on the same user-defined Docker network). `microsocks` listens on `0.0.0.0:1080` *inside* the container, with no auth — any sibling container in that namespace gets a free VPN exit. `-p 127.0.0.1::1080` only restricts host-side access; it does nothing here.
- **The VPN only works inside the container.** `curl` on the host does not go through it. Always `docker exec <container> <command>`, or use the SOCKS5 path from "Recipe: Browser through VPN".
- **If `nvpn-client --connect` fails**, the upstream may be down or your `UDID` may be wrong/expired. Check `docker logs <name>` and `docker exec <name> tail /var/log/nvpn-client/nvpn-client.log`, then see `references/troubleshooting.md`. As of `nvpn-client` 0.9.x, the UDID alone is sufficient — a stale `ELYSIUM_AUTH_CLIENT_KEY` will *break* auth.

## Host-side cleanup (rare)

The per-container teardown in Step 6 / "Recipe: Multiple Locations at Once" is enough for normal use. Only if `wg0` or its policy routes have leaked onto the host (e.g. a container was killed with SIGKILL and other VPNs/SSH sessions broke), run:

```bash
sudo ./scripts/vpn-cleanup.sh
```

See `references/troubleshooting.md` → "OpenVPN / Other VPN Broken After Running Agent VPN" for full diagnosis.

## Entrypoint Commands

- `daemon` — Persistent service mode (default). Connects, stays alive, auto-reconnects with exponential backoff (10s → 300s). Exits non-zero after `MAX_INITIAL_CONNECT_ATTEMPTS` (default 10) consecutive failures on the *first* connect, so a bad UDID surfaces as `Exited(1)` instead of an "Up" container silently leaking via the host network.
- `connect` — One-shot: authenticate, bring up tunnel, print egress IP, then exit.
- `locations` — Pass through to `nvpn-client --locations` (extra args supported, e.g. `locations --format=json`).
- `status` — Show `wg show wg0` + tail of `/var/log/nvpn-client/nvpn-client.log`.
- `stop` — Bring down wg0 + microsocks cleanly.

**Tunnel-ready signal.** While the tunnel is fully up the entrypoint maintains a flag file at `/var/run/vpn-up` inside the container. Recipes can use `docker exec <name> test -e /var/run/vpn-up` as a precondition to avoid sending traffic before the tunnel is ready (which would fail open via the host network on some misconfigurations).

## Further reading

Loaded on demand — read these only when you hit a case the recipes above don't cover:

- `references/architecture.md` — components (`nvpn-client`, `wireguard-go`, `microsocks`), entrypoint responsibilities, full env-var table, connection flow.
- `references/troubleshooting.md` — symptoms → fixes for auth, DNS, routing, and host-side leaks.
- `references/upgrading-nvpn-client.md` — bumping the bundled deb in `data/debs/`.
- `assets/sample-config.example` — template for the optional bind-mount config workflow (copy to `assets/sample-config`, which is gitignored).
