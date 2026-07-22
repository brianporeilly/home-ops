#!/bin/sh
set -eu

FAILURES=0

register_slack() {
  app_name="$1"
  base_url="$2"
  api_path="$3"
  api_key="$4"
  on_flags="$5"

  echo "Waiting for ${app_name} to become ready..."
  until curl -sf -H "X-Api-Key: ${api_key}" "${base_url}/api/${api_path}/system/status" >/dev/null 2>&1; do
    sleep 3
  done

  existing="$(curl -s -H "X-Api-Key: ${api_key}" "${base_url}/api/${api_path}/notification" \
    | jq -r '.[]? | select(.name=="Slack") | .id' | head -n1)"

  payload=$(cat <<JSON
{
  "name": "Slack",
  ${on_flags},
  "implementation": "Slack",
  "implementationName": "Slack",
  "configContract": "SlackSettings",
  "fields": [
    {"name": "webHookUrl", "value": "${SLACK_WEBHOOK_URL}"},
    {"name": "username", "value": "${app_name}"}
  ],
  "tags": []
}
JSON
)

  response_file=$(mktemp)
  if [ -n "${existing:-}" ]; then
    echo "${app_name}: Slack notification already registered (id=${existing}), updating..."
    status=$(curl -s -o "$response_file" -w "%{http_code}" -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
      -X PUT "${base_url}/api/${api_path}/notification/${existing}" -d "$payload")
  else
    echo "${app_name}: registering Slack notification..."
    status=$(curl -s -o "$response_file" -w "%{http_code}" -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
      -X POST "${base_url}/api/${api_path}/notification" -d "$payload")
  fi

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    echo "${app_name}: Slack notification synced (status $status)"
  else
    echo "${app_name}: failed to sync Slack notification (status $status):"
    cat "$response_file"
    echo
    FAILURES=$((FAILURES + 1))
  fi
  rm -f "$response_file"
}

register_slack "Sonarr" "http://sonarr.download.svc.cluster.local:8989" "v3" "${SONARR_API_KEY}" \
  '"onGrab": true, "onDownload": true, "onUpgrade": true, "onImportComplete": true, "onRename": true, "onSeriesAdd": true, "onSeriesDelete": true, "onEpisodeFileDelete": true, "onEpisodeFileDeleteForUpgrade": true, "onHealthIssue": true, "onHealthRestored": true, "onApplicationUpdate": true, "onManualInteractionRequired": true'

register_slack "Radarr" "http://radarr.download.svc.cluster.local:7878" "v3" "${RADARR_API_KEY}" \
  '"onGrab": true, "onDownload": true, "onUpgrade": true, "onRename": true, "onMovieAdded": true, "onMovieDelete": true, "onMovieFileDelete": true, "onMovieFileDeleteForUpgrade": true, "onHealthIssue": true, "onHealthRestored": true, "onApplicationUpdate": true, "onManualInteractionRequired": true'

register_slack "Lidarr" "http://lidarr.download.svc.cluster.local:8686" "v1" "${LIDARR_API_KEY}" \
  '"onGrab": true, "onReleaseImport": true, "onUpgrade": true, "onRename": true, "onArtistAdd": true, "onArtistDelete": true, "onAlbumDelete": true, "onHealthIssue": true, "onHealthRestored": true, "onDownloadFailure": true, "onImportFailure": true, "onTrackRetag": true, "onApplicationUpdate": true'

register_slack "Prowlarr" "http://prowlarr.download.svc.cluster.local:9696" "v1" "${PROWLARR_API_KEY}" \
  '"onHealthIssue": true, "onHealthRestored": true, "onApplicationUpdate": true, "onGrab": true'

if [ "$FAILURES" -gt 0 ]; then
  echo "Done with $FAILURES failure(s)."
  exit 1
fi

echo "Done."
