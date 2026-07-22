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

if [ -n "${EXISTING:-}" ]; then
  echo "qbittorrent instance already registered (id=$EXISTING), skipping"
else
  echo "Registering qbittorrent instance..."
  curl -sf -b "$COOKIES" -X POST "$QUI_URL/api/instances" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"qbittorrent\",\"host\":\"${QBT_HOST}\",\"username\":\"${QBT_USERNAME}\",\"password\":\"${QBT_PASSWORD}\"}"
  echo
  echo "Done."
fi
