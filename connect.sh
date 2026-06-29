#!/usr/bin/env bash
set -u

usage() {
  cat >&2 <<'EOF'
Usage: connect <region> [--wait]

Arguments:
  region     PIA server region ID (e.g., ro, japan, us_east, ca_toronto)
  --wait     Block until the new endpoint is confirmed (up to 120s)

Exit codes:
  0  Connected successfully
  1  Error
EOF
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTH_CONF="$SCRIPT_DIR/pia-auth.conf"
REGION_CONF="$SCRIPT_DIR/region.conf"
SERVICE="pia-connection.service"

REGION="${1:-}"
FLAG_WAIT=false

if [[ -z "$REGION" ]]; then
  usage
fi
if [[ "${2:-}" == "--wait" ]]; then
  FLAG_WAIT=true
elif [[ -n "${2:-}" ]]; then
  usage
fi

if [[ ! -f "$AUTH_CONF" ]]; then
  echo "Missing $AUTH_CONF — create it with PIA_USER and PIA_PASS" >&2
  exit 1
fi
source "$AUTH_CONF"
if [[ -z "${PIA_USER:-}" || -z "${PIA_PASS:-}" ]]; then
  echo "$AUTH_CONF must define PIA_USER and PIA_PASS" >&2
  exit 1
fi

if [[ ! -f "$REGION_CONF" ]]; then
  echo "Missing $REGION_CONF" >&2
  exit 1
fi

if ! grep -q '^PREFERRED_REGION=' "$REGION_CONF"; then
  echo "$REGION_CONF is missing PREFERRED_REGION" >&2
  exit 1
fi

echo "Switching to $REGION..."
sed -i.bak "s/^PREFERRED_REGION=.*/PREFERRED_REGION=$REGION/" "$REGION_CONF"
rm -f "${REGION_CONF}.bak"

echo "Restarting $SERVICE..."

old_pubkey=$(wg show pia public-key 2>/dev/null || true)

if ! systemctl restart "$SERVICE"; then
  echo "systemctl restart failed — status below:" >&2
  systemctl status "$SERVICE" --no-pager >&2
  exit 1
fi
echo "Service restarted."

if ! $FLAG_WAIT; then
  echo "Connected to $REGION."
  exit 0
fi

echo -n "Waiting for new connection"
i=0
while [[ $i -lt 120 ]]; do
  new_pubkey=$(wg show pia public-key 2>/dev/null || true)
  if [[ -n "$new_pubkey" && "$new_pubkey" != "$old_pubkey" ]]; then
    endpoint=$(wg show pia endpoints 2>/dev/null | awk '{print $2}' || true)
    echo " connected ($endpoint)"
    exit 0
  fi
  echo -n "."
  i=$((i + 1))
  sleep 1
done
echo
echo "Timed out waiting for new connection after 120s" >&2
exit 1
