#!/bin/sh
set -eu

PROWLARR_URL="http://prowlarr.download.svc.cluster.local:9696"

echo "Waiting for prowlarr to become ready..."
until curl -sf -H "X-Api-Key: ${PROWLARR_API_KEY}" "$PROWLARR_URL/api/v1/system/status" >/dev/null 2>&1; do
  sleep 3
done

register_app() {
  name="$1"
  base_url="$2"
  api_key="$3"
  sync_categories="$4"
  anime_sync_categories="${5:-}"

  existing="$(curl -s -H "X-Api-Key: ${PROWLARR_API_KEY}" "$PROWLARR_URL/api/v1/applications" \
    | jq -r --arg name "$name" '.[]? | select(.name==$name) | .id' | head -n1)"

  if [ -n "${existing:-}" ]; then
    echo "$name already registered in Prowlarr (id=$existing), skipping"
    return 0
  fi

  fields="[
    {\"name\":\"prowlarrUrl\",\"value\":\"${PROWLARR_URL}\"},
    {\"name\":\"baseUrl\",\"value\":\"${base_url}\"},
    {\"name\":\"apiKey\",\"value\":\"${api_key}\"},
    {\"name\":\"syncCategories\",\"value\":${sync_categories}}"
  if [ -n "$anime_sync_categories" ]; then
    fields="${fields},{\"name\":\"animeSyncCategories\",\"value\":${anime_sync_categories}}"
  fi
  fields="${fields}]"

  echo "Registering $name in Prowlarr..."
  curl -sf -H "X-Api-Key: ${PROWLARR_API_KEY}" -H "Content-Type: application/json" \
    -X POST "$PROWLARR_URL/api/v1/applications" \
    -d "{\"name\":\"${name}\",\"syncLevel\":\"fullSync\",\"implementation\":\"${name}\",\"implementationName\":\"${name}\",\"configContract\":\"${name}Settings\",\"fields\":${fields},\"tags\":[]}"
  echo
}

register_app "Sonarr" "http://sonarr.download.svc.cluster.local:8989" "${SONARR_API_KEY}" \
  "[5000,5010,5020,5030,5040,5045,5050,5090]" "[5070]"

register_app "Radarr" "http://radarr.download.svc.cluster.local:7878" "${RADARR_API_KEY}" \
  "[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]"

register_app "Lidarr" "http://lidarr.download.svc.cluster.local:8686" "${LIDARR_API_KEY}" \
  "[3000,3010,3030,3040,3050,3060]"

echo "Done."
