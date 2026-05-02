#!/bin/bash
# Agent VPN — container entrypoint (nvpn-client 0.9.x architecture)
#
# Compared to the old wg-client/sprinkler-wireguard-client-daemon stack, the
# new nvpn-client owns server discovery (`--locations`) and config generation
# (`--connect --location=<loc>`), but does NOT bring up the wg0 interface
# itself. We do that here, plus run the SOCKS5 proxy and a reconnect loop.
#
# We deliberately do NOT use `set -e`. The script handles failures explicitly
# via `if`/`||`/`return 1` everywhere. `set -e` is a sharp edge here because:
#   1. It would kill the entrypoint on `chmod`/`sed` failures against
#      read-only bind-mounted configs, instead of degrading gracefully.
#   2. It interacts unpredictably with the reconnect loop's `||` patterns
#      and could mask the explicit retry semantics with silent exits.

CONFIG_DIR="/etc/nvpn-client"
CONFIG="${CONFIG_DIR}/config"
LOG_DIR="/var/log/nvpn-client"
WG_CONF="/etc/wireguard/wg0.conf"
TUNNEL_UP_FLAG="/var/run/vpn-up"

HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
RECONNECT_BACKOFF_INITIAL="${RECONNECT_BACKOFF_INITIAL:-10}"
RECONNECT_BACKOFF_MAX="${RECONNECT_BACKOFF_MAX:-300}"

# After this many consecutive failed connect attempts in daemon mode, exit
# non-zero so the container shows up as `Exited(1)` in `docker ps -a` instead
# of silently retrying forever. This is the fail-fast guardrail that surfaces
# bad UDIDs / network outages to operators (and to AI agents using docker
# logs as their primary signal).
MAX_INITIAL_CONNECT_ATTEMPTS="${MAX_INITIAL_CONNECT_ATTEMPTS:-10}"

mkdir -p "$LOG_DIR" "$CONFIG_DIR" /etc/wireguard

cleanup() {
    echo "[entrypoint] Shutting down — stopping SOCKS5 proxy and tearing down wg0..."
    teardown_firewall
    pkill -x microsocks 2>/dev/null || true
    wg-quick down wg0 2>/dev/null || true
    rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
    echo "[entrypoint] Cleanup complete."
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

echo "=== Agent VPN (nvpn-client) ==="

# ---- Patch /etc/nvpn-client/config from -e overrides ----------------------
# nvpn-client reads the env file, so we want any docker -e values to land
# in the file (so manual `nvpn-client` invocations inside the container
# also see them).
#
# If the config is bind-mounted read-only (the documented sample-config
# overlay workflow), skip patching entirely and trust the mount. The user
# is then responsible for putting all required values in the mounted file.
if [ -w "$CONFIG" ]; then
    patch_config_var() {
        local var="$1" val="$2"
        [ -z "$val" ] && return 0
        if grep -q "^${var}=" "$CONFIG" 2>/dev/null; then
            # Use a delimiter unlikely to appear in the value
            sed -i "s|^${var}=.*|${var}=${val}|" "$CONFIG" 2>/dev/null || true
        else
            printf '%s=%s\n' "$var" "$val" >> "$CONFIG" 2>/dev/null || true
        fi
    }
    for v in UDID ELYSIUM_AUTH_CLIENT_KEY ELYSIUM_AUTH_CLIENT_NAME VPN_SERVICE_BASE_URL ELYSIUM_CERT_PINS DISCOVERY_CERT_PINS; do
        patch_config_var "$v" "${!v}"
    done

    # Strip any line whose value is still an unresolved REPLACE_WITH_* placeholder.
    # Otherwise nvpn-client would send the placeholder string to Elysium and get
    # back a 401, which is confusing to debug. This guards against partially
    # populated config.template files baked at build time.
    sed -i '/^[A-Z_]*=REPLACE_WITH_/d' "$CONFIG" 2>/dev/null || true

    chmod 600 "$CONFIG" 2>/dev/null || true
else
    echo "[entrypoint] $CONFIG is read-only; skipping env-var patching (using mounted file as-is)"
fi

# ---- Resolve location -----------------------------------------------------
# VPN_LOCATION can come from `docker run -e VPN_LOCATION=<loc>`. Two formats
# are supported (auto-detected):
#   - city name      (e.g. "Tokyo", "Palo Alto", "Frankfurt")  → --format=city
#   - location key   (e.g. "JP-40-TOKYO", "DE-1-FRANKFURT")    → --format=location-key
# Discover both via `nvpn-client --locations` and `--locations --format=location-key`.
LOCATION="${VPN_LOCATION:-Palo Alto}"

# Auto-detect format from the value shape. Location keys look like
# `XX-YY-CITY-NAME` (uppercase + digits + hyphens). Anything else is a city.
if [[ "$LOCATION" =~ ^[A-Z0-9]+-[A-Z0-9]+-[A-Z0-9-]+$ ]]; then
    LOCATION_FORMAT="location-key"
else
    LOCATION_FORMAT="city"
fi
# Override if explicitly set
LOCATION_FORMAT="${VPN_LOCATION_FORMAT:-$LOCATION_FORMAT}"

# ---- Helpers --------------------------------------------------------------
setup_firewall() {
    # Kill switch: block all egress that doesn't go through the WireGuard
    # tunnel or to the tunnel endpoint itself. If wg0 goes down, traffic is
    # blocked entirely — no fallback to the container's default route (Docker
    # bridge → host network). Also enforces DNS-over-tunnel: only the tunnel's
    # DNS server is reachable on port 53.
    #
    # Called after every successful `wg-quick up wg0`. Safe to call repeatedly
    # (flushes first).

    local ep_addr ep_ip ep_port tunnel_dns

    ep_addr=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | head -1)
    ep_ip=$(echo "$ep_addr" | cut -d: -f1)
    ep_port=$(echo "$ep_addr" | rev | cut -d: -f1 | rev)
    tunnel_dns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)

    if [ -z "$ep_ip" ]; then
        echo "[firewall] WARNING: could not determine WireGuard endpoint; kill switch NOT active"
        return 0
    fi

    # Flush any previous rules from a prior connect cycle
    iptables -F OUTPUT 2>/dev/null || true
    iptables -P OUTPUT DROP

    # Loopback — always allowed
    iptables -A OUTPUT -o lo -j ACCEPT

    # WireGuard endpoint — UDP encapsulation must reach the real server
    iptables -A OUTPUT -p udp -d "$ep_ip" --dport "${ep_port:-51820}" -j ACCEPT

    # DNS — only to the tunnel's DNS server (prevents DNS leaks via hardcoded resolvers)
    if [ -n "$tunnel_dns" ]; then
        iptables -A OUTPUT -p udp --dport 53 -d "$tunnel_dns" -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 53 -d "$tunnel_dns" -j ACCEPT
        iptables -A OUTPUT -p udp --dport 53 -j DROP
        iptables -A OUTPUT -p tcp --dport 53 -j DROP
    fi

    # Everything through the tunnel — allowed
    iptables -A OUTPUT -o wg0 -j ACCEPT

    echo "[firewall] Kill switch active: ep=${ep_ip}:${ep_port:-51820} dns=${tunnel_dns:-none}"
}

teardown_firewall() {
    iptables -F OUTPUT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
}

ensure_socks5() {
    # !!! INVARIANT — DO NOT BREAK !!!
    # Only call AFTER `wg-quick up wg0` has succeeded. microsocks listens on
    # 0.0.0.0:1080 inside the container; once wg0 is up, every TCP connection
    # it opens egresses via the tunnel. If we started microsocks BEFORE wg0,
    # an early client connection would silently exit via the container's
    # default route (the host network), leaking the real IP. The host-side
    # `-p 127.0.0.1::1080` only restricts who can connect, not where the
    # proxied traffic exits.
    if pgrep -x microsocks >/dev/null 2>&1; then
        return 0
    fi
    if ! command -v microsocks >/dev/null 2>&1; then
        return 0
    fi
    echo "[entrypoint] Starting SOCKS5 proxy on :1080"
    microsocks -i 0.0.0.0 -p 1080 >/var/log/microsocks.log 2>&1 &
}

connect_once() {
    rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
    echo "[entrypoint] Connecting via location='${LOCATION}' (format=${LOCATION_FORMAT}) ..."
    # Send nvpn-client logs to stderr so connect failures (auth, location
    # not found, network issues) surface in `docker logs`. Otherwise they'd
    # be silently buried in /var/log/nvpn-client/nvpn-client.log inside the
    # container.
    if ! /usr/bin/nvpn-client \
            --env-file="$CONFIG" \
            --connect \
            --location="$LOCATION" \
            --format="$LOCATION_FORMAT" \
            --logfile=/dev/stderr \
            --loglevel=info; then
        echo "[entrypoint] nvpn-client --connect failed"
        return 1
    fi
    if [ ! -f "$WG_CONF" ]; then
        echo "[entrypoint] No wg0.conf generated at $WG_CONF"
        return 1
    fi

    # Strip DNS directive — Alpine doesn't ship resolvconf and wg-quick would
    # fail with `resolvconf: command not found`. We re-apply the DNS server
    # manually below by writing /etc/resolv.conf directly.
    #
    # Note: declare `local wg_dns` separately from the assignment. If you
    # collapse them into `local wg_dns=$(...)`, bash propagates `local`'s
    # exit code (always 0) instead of grep's, masking parse failures.
    local wg_dns
    wg_dns=$(grep -oP '^DNS\s*=\s*\K.*' "$WG_CONF" | tr -d ' ' | head -1 || true)
    sed -i '/^DNS\s*=/d' "$WG_CONF"

    # Capture the default gateway BEFORE wg-quick adds policy routing, so we
    # can create an explicit host route for the WireGuard endpoint below.
    local default_gw default_dev
    default_gw=$(ip route show default | awk '/default/ {print $3; exit}')
    default_dev=$(ip route show default | awk '/default/ {print $5; exit}')

    echo "[entrypoint] Bringing up wg0..."
    if ! wg-quick up wg0; then
        echo "[entrypoint] wg-quick up wg0 failed"
        return 1
    fi
    echo "[entrypoint] Tunnel is UP"

    # Workaround: wg-quick's fwmark-based policy routing (table 51820, mark
    # 0xca6c) relies on the kernel honouring the fwmark on WireGuard's own
    # UDP encapsulation packets. Some VM kernels (notably Rancher Desktop's
    # 6.6.x-virt) don't apply the fwmark correctly, causing the endpoint's
    # UDP traffic to loop back through wg0 instead of exiting via eth0.
    # Adding an explicit /32 host route for the endpoint through the
    # original default gateway is a safe, idempotent fix that works on all
    # kernels — if fwmark works, the explicit route is harmless (fwmark
    # matches first); if fwmark is broken, the host route saves the tunnel.
    if [ -n "$default_gw" ] && [ -n "$default_dev" ]; then
        local ep_ip
        ep_ip=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1)
        if [ -n "$ep_ip" ]; then
            ip route add "$ep_ip/32" via "$default_gw" dev "$default_dev" 2>/dev/null || true
            echo "[entrypoint] Pinned endpoint $ep_ip via $default_gw dev $default_dev"
        fi
    fi

    if [ -n "$wg_dns" ]; then
        # Comma-separated list possible — take the first
        local first_dns
        first_dns="${wg_dns%%,*}"
        echo "nameserver $first_dns" > /etc/resolv.conf
        echo "[entrypoint] DNS set to $first_dns"
    fi

    setup_firewall
    ensure_socks5

    # Mark tunnel as up only after every prerequisite succeeded. Recipes /
    # external probes can use `docker exec <name> test -e /var/run/vpn-up`
    # as a fail-fast precondition before sending traffic through the container.
    mkdir -p "$(dirname "$TUNNEL_UP_FLAG")" 2>/dev/null || true
    : > "$TUNNEL_UP_FLAG" 2>/dev/null || true
}

healthcheck() {
    wg show wg0 >/dev/null 2>&1 || return 1
    local rx
    rx=$(wg show wg0 transfer 2>/dev/null | awk '{print $2}')
    [ -n "$rx" ] || return 1
    return 0
}

# ---- Dispatch -------------------------------------------------------------
case "${1:-daemon}" in
    locations)
        # Print what's available without connecting. Useful for inventory.
        # Route logs to stderr so users see fatal auth errors instead of a
        # silent exit (default logfile is /var/log/nvpn-client/...).
        exec /usr/bin/nvpn-client \
            --env-file="$CONFIG" \
            --logfile=/dev/stderr \
            --loglevel=info \
            --locations "${@:2}"
        ;;

    connect)
        # One-shot: connect, bring up tunnel, print egress IP, exit.
        connect_once
        echo "[entrypoint] Egress IP check:"
        curl -s -m 10 https://api.ipify.org && echo ""
        ;;

    daemon|start)
        # Initial connect with bounded retries. If we never come up after
        # MAX_INITIAL_CONNECT_ATTEMPTS, exit non-zero so the container shows
        # `Exited(1)` and operators (or AI agents) immediately see the
        # failure instead of a "Up" container that's silently leaking via
        # the host network.
        attempt=1
        while ! connect_once; do
            if [ "$attempt" -ge "$MAX_INITIAL_CONNECT_ATTEMPTS" ]; then
                echo "[entrypoint] FATAL: connect failed ${attempt} consecutive times; giving up."
                echo "[entrypoint] Common causes: bad UDID, expired UDID, Elysium 401, network unreachable."
                echo "[entrypoint] See: docker logs <name>  and  references/troubleshooting.md"
                exit 1
            fi
            wait_secs=$(( RECONNECT_BACKOFF_INITIAL * attempt ))
            [ "$wait_secs" -gt "$RECONNECT_BACKOFF_MAX" ] && wait_secs="$RECONNECT_BACKOFF_MAX"
            echo "[entrypoint] Initial connect attempt ${attempt}/${MAX_INITIAL_CONNECT_ATTEMPTS} failed; retrying in ${wait_secs}s..."
            sleep "$wait_secs" &
            wait $! || true
            attempt=$((attempt + 1))
        done

        # Steady-state health-check loop. Failures here are tolerated forever
        # with exponential backoff — once we've connected at least once, a
        # transient outage shouldn't kill the container.
        backoff="$RECONNECT_BACKOFF_INITIAL"
        while true; do
            sleep "$HEALTH_INTERVAL" &
            wait $! || true
            if healthcheck; then
                backoff="$RECONNECT_BACKOFF_INITIAL"
                continue
            fi
            rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
            echo "[entrypoint] Tunnel down, reconnecting in ${backoff}s..."
            teardown_firewall
            wg-quick down wg0 2>/dev/null || true
            sleep "$backoff" &
            wait $! || true
            if connect_once; then
                echo "[entrypoint] Reconnected."
                backoff="$RECONNECT_BACKOFF_INITIAL"
            else
                if [ "$backoff" -lt "$RECONNECT_BACKOFF_MAX" ]; then
                    backoff=$((backoff * 2))
                    [ "$backoff" -gt "$RECONNECT_BACKOFF_MAX" ] && backoff="$RECONNECT_BACKOFF_MAX"
                fi
            fi
        done
        ;;

    safefetch)
        # Fetch a URL through the VPN with prompt injection scanning.
        # Usage: docker exec <name> safefetch <url> [curl-options...]
        # Exit codes: 0 = clean, 77 = PI detected, 1 = fetch error
        SAFEFETCH_TIMEOUT="${SAFEFETCH_TIMEOUT:-30}"
        SAFEFETCH_LOG="/var/log/safefetch.log"
        url="${2:-}"
        if [ -z "$url" ]; then
            echo "Usage: safefetch <url> [curl-options...]" >&2
            exit 1
        fi
        shift 2  # drop "safefetch" and url, leaving extra curl args

        fetch_output=$(curl -s -m "$SAFEFETCH_TIMEOUT" \
            -A "Mozilla/5.0 (compatible; agentvpn safefetch)" \
            "$@" "$url" 2>/dev/null)
        fetch_rc=$?
        if [ "$fetch_rc" -ne 0 ]; then
            ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            echo "${ts} ${url} fetch_error 0 error" >> "$SAFEFETCH_LOG" 2>/dev/null || true
            echo "[safefetch] curl failed (exit $fetch_rc)" >&2
            exit 1
        fi

        content_len=${#fetch_output}
        scan_stderr=$(mktemp)
        printf '%s' "$fetch_output" | /usr/local/bin/pi-scan.sh 2>"$scan_stderr"
        scan_rc=$?
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        if [ "$scan_rc" -eq 77 ]; then
            echo "${ts} ${url} 200 ${content_len} blocked" >> "$SAFEFETCH_LOG" 2>/dev/null || true
            cat "$scan_stderr" >&2
            rm -f "$scan_stderr"
            exit 77
        fi

        echo "${ts} ${url} 200 ${content_len} clean" >> "$SAFEFETCH_LOG" 2>/dev/null || true
        rm -f "$scan_stderr"
        exit 0
        ;;

    auditlog)
        # Dump or tail the safefetch audit log.
        # Usage: docker exec <name> auditlog [tail-args...]
        SAFEFETCH_LOG="/var/log/safefetch.log"
        if [ ! -f "$SAFEFETCH_LOG" ]; then
            echo "No safefetch audit log yet." >&2
            exit 0
        fi
        if [ $# -gt 1 ]; then
            shift  # drop "auditlog"
            tail "$@" "$SAFEFETCH_LOG"
        else
            cat "$SAFEFETCH_LOG"
        fi
        ;;

    status)
        echo "WireGuard status:"
        wg show wg0 || echo "wg0 interface not up"
        echo ""
        echo "Service logs (last 20 lines):"
        tail -n 20 "$LOG_DIR/nvpn-client.log" 2>/dev/null || echo "No logs yet"
        ;;

    down|stop)
        cleanup
        ;;

    *)
        echo "Usage: $0 {daemon|connect|locations|status|safefetch|auditlog|stop}"
        echo ""
        echo "  daemon     persistent mode with health checks + reconnect (default)"
        echo "  connect    one-shot connect, print egress IP, exit"
        echo "  locations  list available VPN locations (passes extra args to nvpn-client)"
        echo "  safefetch  fetch URL through VPN with PI scanning (extra args passed to curl)"
        echo "  auditlog   dump safefetch audit log (extra args passed to tail)"
        echo "  status     show wg0 + recent client logs"
        echo "  stop       tear down tunnel cleanly"
        echo ""
        echo "Env:"
        echo "  VPN_LOCATION                  city ('Tokyo') or location key ('JP-40-TOKYO')"
        echo "                                (default: 'Palo Alto'; format auto-detected)"
        echo "  VPN_LOCATION_FORMAT           optional override: 'city' | 'location-key'"
        echo "  UDID                          device UDID (required, overrides config file)"
        echo "  ELYSIUM_AUTH_CLIENT_NAME      optional, default 'sprinkler'"
        echo "  VPN_SERVICE_BASE_URL          optional, default https://api.se-platform.com"
        echo "  ELYSIUM_AUTH_CLIENT_KEY       legacy / no longer required by 0.9.x"
        echo "  HEALTH_INTERVAL               seconds between healthchecks (default 60)"
        echo "  RECONNECT_BACKOFF_INITIAL     seconds (default 10)"
        echo "  RECONNECT_BACKOFF_MAX         seconds (default 300)"
        echo "  MAX_INITIAL_CONNECT_ATTEMPTS  fail-fast cap on first-time connect (default 10)"
        echo "  SAFEFETCH_TIMEOUT             curl timeout for safefetch in seconds (default 30)"
        exit 1
        ;;
esac
