#!/usr/bin/env bash
# ============================================================
# lib/grafana_api.sh
# Grafana API wrapper - folder CRUD, alert rule CRUD
# Source this file: source scripts/lib/grafana_api.sh
# ============================================================
set -u

: "${GRAFANA_URL:?GRAFANA_URL required}"
: "${GRAFANA_TOKEN:?GRAFANA_TOKEN required}"
: "${GRAFANA_USER:=""}"
: "${GRAFANA_PASS:=""}"

AUTH_HEADER="Authorization: Bearer ${GRAFANA_TOKEN}"
CT_JSON="Content-Type: application/json"

_curl() {
  curl -s -H "$AUTH_HEADER" -H "$CT_JSON" "$@"
}

_curl_auth() {
  if [[ -n "${GRAFANA_USER:-}" && -n "${GRAFANA_PASS:-}" ]]; then
    curl -s -u "${GRAFANA_USER}:${GRAFANA_PASS}" -H "$CT_JSON" "$@"
  else
    _curl "$@"
  fi
}

grafana_health_check() {
  local code
  code=$(_curl_auth -o /dev/null -w "%{http_code}" "${GRAFANA_URL}/api/health")
  if [[ "$code" != "200" ]]; then
    echo "ERROR: Grafana health check failed (HTTP $code)" >&2
    return 1
  fi
  return 0
}

grafana_folder_get() {
  local folder_title="$1"
  local resp uid
  resp=$(_curl_auth "${GRAFANA_URL}/api/folders?limit=1000")
  uid=$(echo "$resp" | jq -r --arg t "$folder_title" '.[] | select(.title==$t) | .uid // empty')
  echo "$uid"
}

grafana_folder_create() {
  local folder_title="$1"
  local resp uid
  resp=$(_curl_auth -X POST "${GRAFANA_URL}/api/folders" \
    -d "{\"title\": \"$folder_title\"}")
  uid=$(echo "$resp" | jq -r '.uid // empty')
  if [[ -z "$uid" ]]; then
    echo "ERROR: Failed to create folder '$folder_title': $resp" >&2
    return 1
  fi
  echo "$uid"
}

grafana_folder_ensure() {
  local folder_title="$1"
  local uid
  uid=$(grafana_folder_get "$folder_title")
  if [[ -z "$uid" ]]; then
    uid=$(grafana_folder_create "$folder_title")
  fi
  echo "$uid"
}

grafana_list_all_rules() {
  _curl_auth "${GRAFANA_URL}/api/v1/provisioning/alert-rules"
}

grafana_list_folder_rules() {
  local folder_uid="$1"
  _curl_auth "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
    | jq --arg fuid "$folder_uid" '[.[] | select(.folderUID == $fuid)]'
}

grafana_rule_create() {
  local payload="$1"
  local code resp_file
  resp_file=$(mktemp /tmp/gf_create_XXXXXX.json)
  code=$(_curl_auth -X POST "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
    -d "$payload" -o "$resp_file" -w "%{http_code}")
  if [[ "$code" == "201" || "$code" == "200" ]]; then
    rm -f "$resp_file"
    return 0
  else
    echo "ERROR: Create rule failed (HTTP $code): $(cat "$resp_file" 2>/dev/null)" >&2
    rm -f "$resp_file"
    return 1
  fi
}

grafana_rule_update() {
  local rule_uid="$1"
  local payload="$2"
  local code resp_file
  resp_file=$(mktemp /tmp/gf_update_XXXXXX.json)
  code=$(_curl_auth -X PUT "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${rule_uid}" \
    -d "$payload" -o "$resp_file" -w "%{http_code}")
  if [[ "$code" == "200" ]]; then
    rm -f "$resp_file"
    return 0
  else
    echo "ERROR: Update rule $rule_uid failed (HTTP $code): $(cat "$resp_file" 2>/dev/null)" >&2
    rm -f "$resp_file"
    return 1
  fi
}

grafana_rule_delete() {
  local rule_uid="$1"
  local code
  code=$(_curl_auth -X DELETE "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${rule_uid}" \
    -o /dev/null -w "%{http_code}")
  if [[ "$code" == "204" || "$code" == "200" ]]; then
    return 0
  else
    echo "ERROR: Delete rule $rule_uid failed (HTTP $code)" >&2
    return 1
  fi
}
