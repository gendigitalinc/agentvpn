# Agent VPN Troubleshooting (nvpn-client 0.9.x)

## `nvpn-client --connect` fails with `401 Authorization failed. Invalid auth key`

This is the most common failure. Causes, in order of likelihood:

1. **Stale `ELYSIUM_AUTH_CLIENT_KEY` in the config.** As of 0.9.x, the UDID alone is sufficient for auth; an old/wrong client key value (including the `REPLACE_WITH_BASE64_KEY` placeholder from earlier templates) will be sent to Elysium and rejected. Inspect:
   ```bash
   docker exec vpn-tokyo cat /etc/nvpn-client/config
   ```
   If you see `ELYSIUM_AUTH_CLIENT_KEY=...` with anything other than a known-good value, remove that line. The entrypoint auto-strips `REPLACE_WITH_*` placeholders, but explicit-but-stale values survive.

2. **Wrong/expired UDID.** Verify it matches a current Agent VPN device identifier (`U1.<uuid>.<region>.<64-hex>`):
   ```bash
   docker exec vpn-tokyo grep '^UDID=' /etc/nvpn-client/config
   ```

3. **Wrong `ELYSIUM_AUTH_CLIENT_NAME` or `VPN_SERVICE_BASE_URL`.** Defaults (`sprinkler` and `https://api.se-platform.com`) are usually correct; only check if you've overridden them.

Look at the client log for the full error:
```bash
docker exec vpn-tokyo tail -50 /var/log/nvpn-client/nvpn-client.log
```

## TLS / x509 error reaching `api.se-platform.com`

- Make sure `ca-certificates` is installed in the image (it is, by default — only an issue if you've stripped the Dockerfile).
- If your environment requires cert pinning, set `ELYSIUM_CERT_PINS` and/or `DISCOVERY_CERT_PINS` (comma-separated SHA-256 fingerprints).

## No `wg0.conf` generated

- `nvpn-client --connect` printed an error before reaching the discover step. Check the log (above).
- Verify the requested location exists. **`locations` requires `UDID` to be set** in the environment (the binary refuses to run without it, even though the catalog itself is mostly static):
  ```bash
  docker run --rm -e UDID="$AGENTVPN_UDID" agentvpn locations
  ```
- Names are **case-sensitive** (`Tokyo` ≠ `tokyo`) and many cities contain spaces — quote the value: `-e VPN_LOCATION="Palo Alto"`.
- The wrangler/discover service may be temporarily down — try a different location.

## `wg-quick up wg0` fails

- `--cap-add=NET_ADMIN` is required.
- `--device=/dev/net/tun` is required.
- If `sysctl: permission denied` — the Dockerfile's sysctl wrapper should handle this; verify it exists at `/sbin/sysctl`.
- If `resolvconf: command not found` — the entrypoint strips the `DNS=` directive to avoid this (Alpine doesn't ship `resolvconf`); check the `sed '/^DNS\s*=/d'` line in `docker-entrypoint.sh`.
- Make sure `wireguard-go` is present in `$PATH` inside the container — `wg-quick` falls back to it when no kernel module is available:
  ```bash
  docker exec vpn-tokyo which wireguard-go
  ```

## Container starts but `Tunnel is UP` never appears in logs

- The first `nvpn-client --connect` may have failed silently; the entrypoint will retry with backoff. Watch:
  ```bash
  docker logs -f vpn-tokyo
  ```
- If you see `nvpn-client --connect failed` repeatedly, jump to the auth/log section above.

## Tunnel goes down

- The entrypoint health-checks every 60s (`wg show wg0 transfer`) and reconnects with exponential backoff (10s → 300s).
- Manual restart: `docker restart vpn-tokyo`.
- Check reconnect activity: `docker logs vpn-tokyo`.

## Override env vars per-run aren't taking effect

- The entrypoint patches `/etc/nvpn-client/config` from `-e` overrides at startup. Concrete one-liner to confirm a single var landed:
  ```bash
  docker exec vpn-tokyo grep '^UDID=' /etc/nvpn-client/config | sed 's/=.*/=<redacted>/'
  ```
- Or dump the full file:
  ```bash
  docker exec vpn-tokyo cat /etc/nvpn-client/config
  ```
- If a value is missing, the entrypoint only patches `UDID`, `ELYSIUM_AUTH_CLIENT_KEY`, `ELYSIUM_AUTH_CLIENT_NAME`, `VPN_SERVICE_BASE_URL`, `ELYSIUM_CERT_PINS`, `DISCOVERY_CERT_PINS`. Add the var name to the patch loop in `docker-entrypoint.sh` if you need another one.
- If the config is bind-mounted **read-only** (the `assets/sample-config` overlay workflow), the entrypoint logs `[entrypoint] $CONFIG is read-only; skipping env-var patching` and uses the file as-is. In that case `-e VAR=...` overrides are silently ignored — put the values in the mounted file instead, or drop `:ro` from the mount.

## OpenVPN / Other VPN Broken After Running Agent VPN

**Symptom:** After running the Agent VPN, nodes on another VPN (e.g. OpenVPN 10.20.8.0/24) can no longer ping this host, but can still reach other LAN hosts.

**Cause:** WireGuard's `wg-quick` creates policy routing rules (table 51820, fwmark 0xca6c) that capture all unmarked traffic and route it through `wg0`. If the `wg0` interface or these rules leak onto the host (e.g. container killed with SIGKILL, or run with `--network=host`), reply packets to OpenVPN clients get routed through the WireGuard tunnel instead of back through the LAN interface.

**Diagnosis:**
```bash
# Check for leaked interface
ip link show type wireguard

# Check for leaked policy rules
ip rule show
# Bad signs: "lookup 51820" or "suppress_prefixlength 0" rules present

# Check for leaked routing table
ip route show table 51820
# Bad sign: "default dev wg0 scope link"
```

**Fix:**
```bash
sudo ./scripts/vpn-cleanup.sh
```

Or manually:
```bash
sudo wg-quick down wg0 2>/dev/null || sudo ip link delete wg0
sudo ip rule del lookup 51820
sudo ip rule del from all lookup main suppress_prefixlength 0
sudo ip route flush table 51820
```

**Prevention:**
- Always stop containers gracefully (`docker stop`, not `docker kill`).
- Never run the VPN container with `--network=host`.
- The entrypoint includes signal traps to tear down `wg0` on SIGTERM.

## Multiple regions (simultaneous tunnels)

Each region is a **separate container** with its own isolated `wg0`. Use distinct `--name` values and separate `docker run` invocations. Do not rely on one docker-compose service name for every region. Step-by-step commands and cleanup: **`SKILL.md` → Recipe: Multiple Locations at Once**.

## Verifying Egress Location

- The `connect` command prints the egress IP via `api.ipify.org` after the tunnel is up.
- For full geo lookup: `docker exec vpn-tokyo curl -s http://ip-api.com/json`.
- Compare against the location you requested. If it doesn't match, check the resolved server in the wg0 config: `docker exec vpn-tokyo cat /etc/wireguard/wg0.conf | grep -E 'Endpoint|^# '`.

## Upgrading the bundled `nvpn-client` deb

See `references/upgrading-nvpn-client.md` for the upgrade procedure and compatibility checks.
