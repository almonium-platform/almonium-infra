#!/usr/bin/env bash
# Push the dashboards, alert rules, contact point and notification policy in
# this directory to Grafana Cloud. Idempotent: every call is an upsert.
#
#   GRAFANA_TOKEN=<service-account token, Editor role> ./grafana/apply.sh
#
# Resources are written without provenance, so they stay editable in the UI;
# export a UI edit back here (Dashboard > Export > JSON) to keep it.
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-https://almonium.grafana.net}"
: "${GRAFANA_TOKEN:?set GRAFANA_TOKEN to a Grafana service-account token}"
dir="$(cd "$(dirname "$0")" && pwd)"

api() {
  local method="$1" path="$2" body="${3:-}"
  curl -sS --fail-with-body -X "$method" "$GRAFANA_URL$path" \
    -H "Authorization: Bearer $GRAFANA_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Disable-Provenance: true" \
    ${body:+--data-binary "@$body"}
  echo
}

# Folder (created once; 409/412 means it already exists).
curl -sS -o /dev/null -w "folder: %{http_code}\n" -X POST "$GRAFANA_URL/api/folders" \
  -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" \
  -d '{"uid":"almonium","title":"Almonium"}'

# Contact point: update if present, else create.
if ! api PUT /api/v1/provisioning/contact-points/almonium-email "$dir/alerting/contact-point.json" 2>/dev/null; then
  api POST /api/v1/provisioning/contact-points "$dir/alerting/contact-point.json"
fi

api PUT /api/v1/provisioning/policies "$dir/alerting/notification-policy.json"

for group in "$dir"/alerting/rules-*.json; do
  name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$group")"
  api PUT "/api/v1/provisioning/folder/almonium/rule-groups/$name" "$group"
done

for dash in "$dir"/dashboards/*.json; do
  python3 -c 'import json,sys; print(json.dumps({"dashboard": json.load(open(sys.argv[1])), "folderUid": "almonium", "overwrite": True}))' "$dash" \
    > /tmp/grafana-dashboard.json
  api POST /api/dashboards/db /tmp/grafana-dashboard.json
done
