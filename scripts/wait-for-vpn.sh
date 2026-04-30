#!/bin/bash
# Wait for an Agent VPN container's tunnel to come up.
#
# Polls the in-container readiness flag (/var/run/vpn-up) which the entrypoint
# touches only after auth, wg-quick, and microsocks have all succeeded. Exits
# 0 once the flag appears, or non-zero (after dumping `docker logs`) on
# timeout / container exit.
#
# Usage:
#   scripts/wait-for-vpn.sh <container-name> [timeout-seconds]
#
# Example:
#   docker run -d --name vpn-tokyo ... agentvpn daemon
#   scripts/wait-for-vpn.sh vpn-tokyo && \
#     docker exec vpn-tokyo curl -s http://ip-api.com/json

set -u

NAME="${1:-}"
TIMEOUT="${2:-15}"

if [ -z "$NAME" ]; then
    echo "Usage: $0 <container-name> [timeout-seconds]" >&2
    exit 2
fi

for _ in $(seq 1 "$TIMEOUT"); do
    if docker exec "$NAME" test -e /var/run/vpn-up 2>/dev/null; then
        exit 0
    fi
    if ! docker ps --filter "name=^${NAME}$" --filter status=running --format '{{.Names}}' | grep -qx "$NAME"; then
        echo "[wait-for-vpn] Container '$NAME' is not running. Logs:" >&2
        docker logs "$NAME" >&2 2>&1 || true
        exit 1
    fi
    sleep 1
done

echo "[wait-for-vpn] Timed out after ${TIMEOUT}s waiting for /var/run/vpn-up in '$NAME'. Logs:" >&2
docker logs "$NAME" >&2 2>&1 || true
exit 1
