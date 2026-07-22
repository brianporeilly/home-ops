#!/bin/sh
set -eu

QUI_URL="http://qui.download.svc.cluster.local:7476"
QBT_HOST="http://qbittorrent.download.svc.cluster.local:8080"
COOKIES=/tmp/cookies.txt

echo "Waiting for qui to become ready..."
until curl -sf "$QUI_URL/health" >/dev/null 2>&1; do
  sleep 3
done

echo "Waiting for qbittorrent to become ready..."
until curl -sf "$QBT_HOST" >/dev/null 2>&1; do
  sleep 3
done

echo "Running qui setup (no-op if already completed)..."
SETUP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIES" -X POST "$QUI_URL/api/auth/setup" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${QUI_USERNAME}\",\"password\":\"${QUI_PASSWORD}\"}")
echo "Setup responded with status $SETUP_STATUS (200 = created, 400 = already completed, anything else is worth investigating)"

echo "Logging in..."
LOGIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIES" -X POST "$QUI_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${QUI_USERNAME}\",\"password\":\"${QUI_PASSWORD}\"}")

if [ "$LOGIN_STATUS" != "200" ]; then
  echo "Login failed with status $LOGIN_STATUS"
  exit 1
fi

echo "Checking for an existing qbittorrent instance..."
EXISTING="$(curl -s -b "$COOKIES" "$QUI_URL/api/instances" | jq -r --arg host "$QBT_HOST" '.[]? | select(.host==$host) | .id' | head -n1)"

response_file=$(mktemp)
if [ -n "${EXISTING:-}" ]; then
  # Qui stores its own copy of qbittorrent's credentials - if they've since
  # rotated (password/API key change), the entry needs updating every run,
  # not just left alone, or the connection silently goes stale.
  echo "qbittorrent instance already registered (id=$EXISTING), syncing credentials..."
  status=$(curl -s -o "$response_file" -w "%{http_code}" -b "$COOKIES" -X PUT "$QUI_URL/api/instances/${EXISTING}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"qbittorrent\",\"host\":\"${QBT_HOST}\",\"username\":\"${QBT_USERNAME}\",\"password\":\"${QBT_PASSWORD}\"}")
else
  echo "Registering qbittorrent instance..."
  status=$(curl -s -o "$response_file" -w "%{http_code}" -b "$COOKIES" -X POST "$QUI_URL/api/instances" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"qbittorrent\",\"host\":\"${QBT_HOST}\",\"username\":\"${QBT_USERNAME}\",\"password\":\"${QBT_PASSWORD}\"}")
fi

if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
  echo "qbittorrent instance synced (status $status)"
else
  echo "Failed to sync qbittorrent instance (status $status):"
  cat "$response_file"
  echo
  rm -f "$response_file"
  exit 1
fi
rm -f "$response_file"

echo "Done."
