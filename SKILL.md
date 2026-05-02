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

The build pulls `wireguard-go` + `microsocks` from upstream sources, compiles the `pi-ml-scan` ML scanner from Rust, and installs the bundled `nvpn-client` deb from `data/debs/`.

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

## Recipe: Safe Fetch with Prompt Injection Scanning

When an AI agent fetches web content through the VPN, the response may contain prompt injection (PI) attacks — hidden instructions designed to hijack the agent. The `safefetch` command wraps `curl` with automatic PI scanning so malicious content is blocked before it reaches the agent.

**Use `safefetch` instead of raw `curl` whenever an AI agent will process the response.** Raw `curl` via `docker exec` remains available as an escape hatch for cases where you need unfiltered content.

### Basic usage

```bash
docker exec vpn-tokyo safefetch https://example.com/api/data
```

Extra curl options are passed through after the URL:

```bash
docker exec vpn-tokyo safefetch https://example.com -H "Accept: application/json"
```

### Exit codes

- `0` — content is clean; written to stdout
- `77` — prompt injection detected; content suppressed, warning on stderr
- `1` — fetch error (curl failed, URL unreachable, etc.)

### Handling results in agent workflows

```bash
output=$(docker exec vpn-tokyo safefetch https://example.com 2>/tmp/safefetch-err)
rc=$?
if [ "$rc" -eq 77 ]; then
    echo "WARNING: PI detected, content blocked" >&2
    cat /tmp/safefetch-err >&2
elif [ "$rc" -ne 0 ]; then
    echo "Fetch failed" >&2
fi
```

### Audit log

Every `safefetch` call is logged to `/var/log/safefetch.log` inside the container. Each line records: timestamp, URL, HTTP status, content length, and scan result (`clean`, `blocked`, or `error`).

View the log:

```bash
docker exec vpn-tokyo auditlog
```

Tail recent entries:

```bash
docker exec vpn-tokyo auditlog -n 5
```

### Configuring the timeout

The default curl timeout for `safefetch` is 30 seconds. Override via `SAFEFETCH_TIMEOUT`:

```bash
docker run -d --name vpn-tokyo \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -e UDID="$AGENTVPN_UDID" \
  -e VPN_LOCATION="Tokyo" \
  -e SAFEFETCH_TIMEOUT=60 \
  agentvpn daemon
```

### Detection approach

`safefetch` uses a **two-tier** prompt injection scanner:

1. **Tier 1 — Heuristic (regex):** Fast regex scan (`pi-scan.sh`) against a curated pattern file (`pi-patterns.txt`) covering instruction override, role assumption, safety bypass, system prompt extraction, and encoding evasion attempts. Runs in ~0ms.

2. **Tier 2 — ML inference:** If heuristic passes, content is classified by a BERT-based PI model (`pi-ml-scan` binary) using tract-onnx pure-Rust inference. The model (BertForSequenceClassification, 6 layers, hidden=384, INT8 ONNX, ~22 MB) uses 512-token sliding-window chunking with 128-token overlap for long content. Block threshold: 0.99. Runs in ~50-200ms.

Both tiers are fail-open: if the pattern file is missing, the ML binary isn't found, or inference errors occur, content passes through unblocked. The ML tier can be disabled by setting `PI_ML_ENABLED=0` in the container environment.

## Security: Kill Switch and DNS Leak Prevention

The container enforces a network-level kill switch via iptables. Once the WireGuard tunnel is up, firewall rules block all egress traffic except:

- Traffic through the `wg0` tunnel interface
- UDP to the WireGuard endpoint (tunnel maintenance)
- DNS only to the tunnel's DNS server

**If `wg0` goes down, all traffic is blocked** — there is no fallback to the container's default route (Docker bridge to host network). This prevents IP leaks during the window between a tunnel drop and the health-check reconnect.

DNS leak prevention is also enforced at the firewall level: outbound port 53 (UDP/TCP) is only permitted to the tunnel DNS server. A process inside the container cannot bypass this by hardcoding an external DNS resolver.

The kill switch activates automatically — no configuration needed. It is torn down during reconnects (so the client can reach Elysium for re-authentication) and re-established after each successful tunnel setup.

## Critical safety rules

These are constraints the step-by-step recipes don't otherwise force on you. Violating any of them can leak the UDID, leak traffic via the host, or break unrelated VPNs.

- **NEVER push the *built* image to any registry.** A populated `UDID` (whether baked into `config.template` before build or written by `-e UDID=...` at run time) lives in the image filesystem; `docker push` exfiltrates it. Build locally, use locally. (The source repo is safe — committed `config.template` is placeholders only.)
- **Never use `--network=host`.** It leaks WireGuard routes onto the host and breaks other VPNs / SSH.
- **Never share a vpn-\* container's network namespace with an untrusted container** (`--network=container:vpn-tokyo`, or co-locating on the same user-defined Docker network). `microsocks` listens on `0.0.0.0:1080` *inside* the container, with no auth — any sibling container in that namespace gets a free VPN exit. `-p 127.0.0.1::1080` only restricts host-side access; it does nothing here.
- **The VPN only works inside the container.** `curl` on the host does not go through it. Always `docker exec <container> <command>`, or use the SOCKS5 path from "Recipe: Browser through VPN".
- **Use `safefetch` for AI agent workflows.** When an AI agent will process fetched web content, use `docker exec <name> safefetch <url>` instead of raw `curl`. This scans for prompt injection attacks before content reaches the agent. Raw `curl` remains available when unfiltered access is needed.
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
- `safefetch` — Fetch a URL through the VPN with prompt injection scanning. Extra args after the URL are passed to curl. Exit codes: 0 = clean, 77 = PI detected, 1 = fetch error.
- `auditlog` — Dump the safefetch audit log (`/var/log/safefetch.log`). Extra args are passed to `tail` (e.g. `auditlog -n 10`).
- `status` — Show `wg show wg0` + tail of `/var/log/nvpn-client/nvpn-client.log`.
- `stop` — Bring down wg0 + microsocks cleanly.

**Tunnel-ready signal.** While the tunnel is fully up the entrypoint maintains a flag file at `/var/run/vpn-up` inside the container. Recipes can use `docker exec <name> test -e /var/run/vpn-up` as a precondition to avoid sending traffic before the tunnel is ready (which would fail open via the host network on some misconfigurations).

## Bundled resources

- `data/pi-patterns.txt` — Prompt injection heuristic regex patterns used by `pi-scan.sh` and `safefetch`. Curated from public PI research (OWASP LLM Top 10, academic adversarial prompt datasets).
- `scripts/pi-scan.sh` — In-container two-tier PI scanner (heuristic + ML). Reads stdin, checks both tiers, exits 0 (clean) or 77 (PI detected). Fail-open on errors.
- `scripts/wait-for-vpn.sh` — Poll `/var/run/vpn-up` in a container; exits non-zero with `docker logs` on timeout or container exit. Use as a precondition before sending traffic.
- `scripts/vpn-cleanup.sh` — Host-side cleanup for leaked `wg0` interface and policy routes (run if other VPNs break after a `docker kill`).
- `tools/pi-ml-scan/` — Rust project for the ML-based PI scanner. Uses `tract-onnx` (pure Rust ONNX inference) with a BERT-based model (6 layers, hidden=384, INT8 ONNX, ~22 MB). Built as a static musl binary in the Docker multi-stage build.
- `tools/pi-ml-scan/download-assets.sh` — Copies model assets from a local Sage installation (`~/.sage/models/v1/pi-model/`). Run once after cloning, before `cargo build`.
- `tests/test-pi-scan.sh` — Test suite for the two-tier PI scanner (21 cases: 17 heuristic + 4 ML integration tests).

## Further reading

Loaded on demand — read these only when you hit a case the recipes above don't cover:

- `references/architecture.md` — components (`nvpn-client`, `wireguard-go`, `microsocks`), entrypoint responsibilities, full env-var table, connection flow.
- `references/troubleshooting.md` — symptoms → fixes for auth, DNS, routing, and host-side leaks.
- `references/upgrading-nvpn-client.md` — bumping the bundled deb in `data/debs/`.
- `assets/sample-config.example` — template for the optional bind-mount config workflow (copy to `assets/sample-config`, which is gitignored).
