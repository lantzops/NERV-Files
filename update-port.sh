#!/bin/sh
###############################################################################
# update-port.sh — NERV port synchronization agent
#
# Polls Gluetun's control API for the current NAT-PMP forwarded port from
# ProtonVPN, then updates qBittorrent's listening port if it has changed.
#
# This is critical for seeding: without a forwarded port that matches
# qBittorrent's configured listening port, incoming peer connections fail
# and your seed ratio tanks because only outbound connections work.
#
# Runs inside the port-sync container on Unit-00's network stack so it
# can reach both Gluetun (localhost:8000) and qBittorrent (localhost:8080).
###############################################################################

GLUETUN_API="http://localhost:8000"
QBIT_API="http://localhost:8080/api/v2"
QBIT_USER="${QBIT_USER:-admin}"
QBIT_PASS="${QBIT_PASS:-adminadmin}"

# --- Step 1: Get forwarded port from Gluetun ---
# Gluetun exposes the port assigned by ProtonVPN via NAT-PMP at this endpoint.
FORWARDED_PORT=$(curl -sf "${GLUETUN_API}/v1/openvpn/portforwarded" 2>/dev/null | jq -r '.port // empty')

if [ -z "$FORWARDED_PORT" ] || [ "$FORWARDED_PORT" = "0" ]; then
  echo "[$(date '+%H:%M:%S')] WARNING: No forwarded port from Gluetun yet. VPN may still be connecting."
  exit 0
fi

# --- Step 2: Authenticate with qBittorrent web API ---
# qBittorrent requires a session cookie (SID) for API calls.
COOKIE=$(curl -sf -c - \
  --data-urlencode "username=${QBIT_USER}" \
  --data-urlencode "password=${QBIT_PASS}" \
  "${QBIT_API}/auth/login" 2>/dev/null | grep -oP 'SID\s+\K\S+')

if [ -z "$COOKIE" ]; then
  echo "[$(date '+%H:%M:%S')] WARNING: Cannot authenticate with qBittorrent. It may not be ready yet."
  exit 0
fi

# --- Step 3: Get qBittorrent's current listening port ---
CURRENT_PORT=$(curl -sf -b "SID=${COOKIE}" \
  "${QBIT_API}/app/preferences" 2>/dev/null | jq -r '.listen_port // empty')

# --- Step 4: Update only if the port has changed ---
if [ "$FORWARDED_PORT" = "$CURRENT_PORT" ]; then
  echo "[$(date '+%H:%M:%S')] Port in sync: ${FORWARDED_PORT}"
  exit 0
fi

echo "[$(date '+%H:%M:%S')] Port mismatch detected!"
echo "  Gluetun forwarded port: ${FORWARDED_PORT}"
echo "  qBittorrent listening:  ${CURRENT_PORT}"
echo "  Updating qBittorrent..."

# Update qBittorrent's listening port via its preferences API.
RESULT=$(curl -sf -b "SID=${COOKIE}" \
  -X POST \
  --data-urlencode "json={\"listen_port\": ${FORWARDED_PORT}}" \
  "${QBIT_API}/app/setPreferences" 2>/dev/null)

echo "[$(date '+%H:%M:%S')] Port updated to ${FORWARDED_PORT}"
