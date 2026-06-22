#!/usr/bin/env bash
# ============================================================
# sync_grafana_alerts.sh
# Core sync logic: plan (diff) → apply (create + delete) → summary
#
# Usage:
#   bash sync_grafana_alerts.sh plan     # dry-run: show diff only
#   bash sync_grafana_alerts.sh apply    # apply changes to Grafana
#   bash sync_grafana_alerts.sh summary  # print summary from last plan
#
# Env vars:
#   GRAFANA_URL, GRAFANA_TOKEN (or GRAFANA_USER + GRAFANA_PASS)
#   AZURE_DATASOURCE_UID
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INVENTORY_FILE="${PROJECT_ROOT}/inventory.json"
THRESHOLDS_FILE="${PROJECT_ROOT}/config/alert_thresholds.json"
MAPPING_FILE="${PROJECT_ROOT}/config/project_mapping.json"
TEMPLATE_DIR="${PROJECT_ROOT}/templates/grafana"
PLAN_FILE="/tmp/grafana_sync_plan.json"
LOG_FILE="/tmp/grafana_sync_$(date +%Y%m%d_%H%M%S).log"

: "${GRAFANA_URL:?GRAFANA_URL required}"
: "${AZURE_DATASOURCE_UID:?AZURE_DATASOURCE_UID required}"

source "${SCRIPT_DIR}/lib/grafana_api.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2; }

calc_threshold() {
  echo "$1 $2" | awk '{printf "%.0f", $1 * $2 / 100}'
}

get_template_file() {
  local res_type="$1"
  case "$res_type" in
    AppServicePlan) echo "${TEMPLATE_DIR}/app_service_plan.json" ;;
    Redis)          echo "${TEMPLATE_DIR}/redis_managed.json" ;;
    SQLServer)      echo "${TEMPLATE_DIR}/sql_server.json" ;;
    *)              echo "" ;;
  esac
}

get_folder_name() {
  local project="$1"
  echo "${project}-Alerts"
}

compute_asp_dynamic_thresholds() {
  local sku="$1"
  local thresholds_json="$2"

  local sku_upper
  sku_upper=$(echo "$sku" | tr '[:lower:]' '[:upper:]')

  local bw_max disk_max socket_max
  bw_max=$(echo "$thresholds_json" | jq -r --arg sku "$sku_upper" '.app_service_plan.sku_bandwidth_bytes_per_min[$sku] // .app_service_plan.sku_bandwidth_bytes_per_min.DEFAULT')
  disk_max=$(echo "$thresholds_json" | jq -r --arg sku "$sku_upper" '.app_service_plan.sku_disk_queue_max[$sku] // .app_service_plan.sku_disk_queue_max.DEFAULT')
  socket_max=$(echo "$thresholds_json" | jq -r '.app_service_plan.socket_max')

  local net_warn net_crit disk_warn disk_crit sock_warn sock_crit
  net_warn=$(calc_threshold "$bw_max" 80)
  net_crit=$(calc_threshold "$bw_max" 90)
  disk_warn=$(calc_threshold "$disk_max" 80)
  disk_crit=$(calc_threshold "$disk_max" 90)
  sock_warn=$(calc_threshold "$socket_max" 80)
  sock_crit=$(calc_threshold "$socket_max" 90)

  echo "$net_warn $net_crit $disk_warn $disk_crit $sock_warn $sock_crit"
}

build_expected_rules() {
  local inventory_json="$1"
  local thresholds_json="$2"

  local expected="[]"

  while IFS= read -r res; do
    local res_type name rg sub_id sku project
    res_type=$(echo "$res" | jq -r '.type')
    name=$(echo "$res" | jq -r '.name')
    rg=$(echo "$res" | jq -r '.resourceGroup')
    sub_id=$(echo "$res" | jq -r '.subscriptionId')
    sku=$(echo "$res" | jq -r '.sku // ""')
    project=$(echo "$res" | jq -r '.project')

    local template_file
    template_file=$(get_template_file "$res_type")
    if [[ ! -f "$template_file" ]]; then
      err "  No template for type=$res_type, skipping $name"
      continue
    fi

    local folder_name
    folder_name=$(get_folder_name "$project")

    local rules_json
    rules_json=$(cat "$template_file")

    rules_json=$(echo "$rules_json" | \
      sed "s|\${AZURE_DATASOURCE_UID}|$AZURE_DATASOURCE_UID|g" | \
      sed "s|\${RESOURCE_GROUP}|$rg|g" | \
      sed "s|\${RESOURCE_NAME}|$name|g" | \
      sed "s|\${ASP_NAME}|$name|g" | \
      sed "s|\${SUBSCRIPTION_ID}|$sub_id|g")

    if [[ "$res_type" == "AppServicePlan" ]]; then
      local thresholds
      thresholds=$(compute_asp_dynamic_thresholds "$sku" "$thresholds_json")
      read -r net_warn net_crit disk_warn disk_crit sock_warn sock_crit <<< "$thresholds"

      rules_json=$(echo "$rules_json" | \
        sed "s|\${NET_IN_WARN_BYTES}|$net_warn|g" | \
        sed "s|\${NET_IN_CRIT_BYTES}|$net_crit|g" | \
        sed "s|\${NET_OUT_WARN_BYTES}|$net_warn|g" | \
        sed "s|\${NET_OUT_CRIT_BYTES}|$net_crit|g" | \
        sed "s|\${SOCK_OUT_WARN}|$sock_warn|g" | \
        sed "s|\${SOCK_OUT_CRIT}|$sock_crit|g" | \
        sed "s|\${DISK_WARN_THRESHOLD}|$disk_warn|g" | \
        sed "s|\${DISK_CRIT_THRESHOLD}|$disk_crit|g")
    fi

    local uid_prefix
    uid_prefix=$(echo "${res_type}-${name}-${rg}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-22)

    rules_json=$(echo "$rules_json" | jq -c \
      --arg prefix "$uid_prefix" \
      --arg folder "$folder_name" \
      --arg res_type "$res_type" \
      '
      [.groups[] | .rules[] |
        .uid = ($prefix + "-" + .uid | .[0:40]) |
        . + {
          _folder: $folder,
          _resourceType: $res_type,
          _resourceName: .title
        }
      ]')

    expected=$(echo "$expected" "$rules_json" | jq -s 'add')
  done < <(echo "$inventory_json" | jq -c '.[]')

  echo "$expected"
}

do_plan() {
  log "==> PLAN MODE: Diff expected vs existing"

  if [[ ! -f "$INVENTORY_FILE" ]]; then
    err "Inventory file not found: $INVENTORY_FILE"
    err "Run discover_resources.sh first."
    exit 1
  fi

  local inventory_json thresholds_json
  inventory_json=$(cat "$INVENTORY_FILE")
  thresholds_json=$(cat "$THRESHOLDS_FILE")

  log "  Building expected rules from inventory..."
  local expected
  expected=$(build_expected_rules "$inventory_json" "$thresholds_json")
  local expected_count
  expected_count=$(echo "$expected" | jq 'length')
  log "  Expected rules: $expected_count"

  log "  Fetching existing rules from Grafana..."
  grafana_health_check || exit 1
  local existing
  existing=$(grafana_list_all_rules)
  local existing_count
  existing_count=$(echo "$existing" | jq 'length')
  log "  Existing rules: $existing_count"

  local expected_uids existing_uids
  expected_uids=$(echo "$expected" | jq '[.[].uid]')
  existing_uids=$(echo "$existing" | jq '[.[].uid]')

  local to_create to_delete
  to_create=$(printf '%s\n%s\n' "$expected_uids" "$existing_uids" | jq -c -s '.[0] - .[1]')
  to_delete=$(printf '%s\n%s\n' "$existing_uids" "$expected_uids" | jq -c -s '.[0] - .[1]')

  local create_count delete_count
  create_count=$(echo "$to_create" | jq 'length')
  delete_count=$(echo "$to_delete" | jq 'length')

  local to_create_rules to_delete_rules
  to_create_rules=$(echo "$expected" | jq -c --argjson uids "$to_create" '[.[] | select(.uid as $u | $uids | index($u))]')
  to_delete_rules=$(echo "$existing" | jq -c --argjson uids "$to_delete" '[.[] | select(.uid as $u | $uids | index($u))]')

  echo "$to_create_rules" > /tmp/gf_to_create.json
  echo "$to_delete_rules" > /tmp/gf_to_delete.json

  jq -n \
    --slurpfile create /tmp/gf_to_create.json \
    --slurpfile delete /tmp/gf_to_delete.json \
    --argjson create_count "$create_count" \
    --argjson delete_count "$delete_count" \
    --argjson expected_count "$expected_count" \
    --argjson existing_count "$existing_count" \
    '{
      expected_total: $expected_count,
      existing_total: $existing_count,
      to_create_count: $create_count,
      to_delete_count: $delete_count,
      to_create: $create[0],
      to_delete: $delete[0]
    }' > "$PLAN_FILE"

  echo ""
  echo "============================================"
  echo " PLAN SUMMARY"
  echo "============================================"
  echo "  Expected rules : $expected_count"
  echo "  Existing rules : $existing_count"
  echo "  To CREATE      : $create_count"
  echo "  To DELETE      : $delete_count"
  echo ""

  if [[ "$create_count" -gt 0 ]]; then
    echo "  Rules to CREATE:"
    echo "$to_create_rules" | jq -r '.[] | "    + [\(._resourceType)] \(._folder) / \(.title)"'
    echo ""
  fi

  if [[ "$delete_count" -gt 0 ]]; then
    echo "  Rules to DELETE (orphaned):"
    echo "$to_delete_rules" | jq -r '.[] | "    - [\(.folderUID)] \(.title)"'
    echo ""
  fi

  if [[ "$create_count" -eq 0 && "$delete_count" -eq 0 ]]; then
    echo "  All rules are in sync. No changes needed."
  fi

  echo "============================================"
  echo " Plan saved to: $PLAN_FILE"
}

do_apply() {
  log "==> APPLY MODE: Applying changes to Grafana"

  if [[ ! -f "$PLAN_FILE" ]]; then
    err "Plan file not found. Run 'plan' first."
    exit 1
  fi

  grafana_health_check || exit 1

  local to_create_rules to_delete_rules
  to_create_rules=$(cat /tmp/gf_to_create.json 2>/dev/null || echo "[]")
  to_delete_rules=$(cat /tmp/gf_to_delete.json 2>/dev/null || echo "[]")

  local create_count delete_count
  create_count=$(echo "$to_create_rules" | jq 'length')
  delete_count=$(echo "$to_delete_rules" | jq 'length')

  log "  To create: $create_count | To delete: $delete_count"

  local created=0 create_failed=0
  local deleted=0 delete_failed=0

  local folder_cache
  declare -A folder_cache

  if [[ "$create_count" -gt 0 ]]; then
    log "  --- Creating new rules ---"
    while IFS= read -r rule; do
      local folder_name title uid
      folder_name=$(echo "$rule" | jq -r '._folder')
      title=$(echo "$rule" | jq -r '.title')
      uid=$(echo "$rule" | jq -r '.uid')

      local folder_uid
      if [[ -n "${folder_cache[$folder_name]:-}" ]]; then
        folder_uid="${folder_cache[$folder_name]}"
      else
        folder_uid=$(grafana_folder_ensure "$folder_name")
        folder_cache[$folder_name]="$folder_uid"
      fi

      local rule_group
      rule_group=$(echo "${title}" | sed 's/\[WARN\] //; s/\[CRIT\] //; s/ - .*//')

      local payload
      payload=$(echo "$rule" | jq -c \
        --arg folder_uid "$folder_uid" \
        --arg rule_group "$rule_group" \
        '{
          title:        .title,
          ruleGroup:    $rule_group,
          folderUID:    $folder_uid,
          for:          .for,
          labels:       .labels,
          annotations:  .annotations,
          condition:    .condition,
          data:         .data,
          noDataState:  (.noDataState  // "NoData"),
          execErrState: (.execErrState // "Error")
        }')

      if grafana_rule_create "$payload"; then
        log "    [OK] $title"
        created=$((created + 1))
      else
        err "    [FAIL] $title"
        create_failed=$((create_failed + 1))
      fi
    done < <(echo "$to_create_rules" | jq -c '.[]')
  fi

  if [[ "$delete_count" -gt 0 ]]; then
    log "  --- Deleting orphaned rules ---"
    while IFS= read -r rule; do
      local uid title
      uid=$(echo "$rule" | jq -r '.uid')
      title=$(echo "$rule" | jq -r '.title')

      if grafana_rule_delete "$uid"; then
        log "    [OK] $title"
        deleted=$((deleted + 1))
      else
        err "    [FAIL] $title"
        delete_failed=$((delete_failed + 1))
      fi
    done < <(echo "$to_delete_rules" | jq -c '.[]')
  fi

  echo ""
  echo "============================================"
  echo " APPLY RESULT"
  echo "============================================"
  echo "  Created : $created OK / $create_failed FAILED"
  echo "  Deleted : $deleted OK / $delete_failed FAILED"
  echo "============================================"

  if [[ "$create_failed" -gt 0 || "$delete_failed" -gt 0 ]]; then
    exit 1
  fi
}

do_summary() {
  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "No plan file found. Run 'plan' first."
    exit 1
  fi

  local plan
  plan=$(cat "$PLAN_FILE")

  local expected existing create_count delete_count
  expected=$(echo "$plan" | jq -r '.expected_total')
  existing=$(echo "$plan" | jq -r '.existing_total')
  create_count=$(echo "$plan" | jq -r '.to_create_count')
  delete_count=$(echo "$plan" | jq -r '.to_delete_count')

  echo "## Grafana Alert Sync Summary"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|-------|"
  echo "| Expected rules | $expected |"
  echo "| Existing rules | $existing |"
  echo "| **To Create** | **$create_count** |"
  echo "| **To Delete** | **$delete_count** |"
  echo ""

  if [[ "$create_count" -gt 0 ]]; then
    echo "### Rules Created"
    echo ""
    local to_create_rules
    to_create_rules=$(cat /tmp/gf_to_create.json 2>/dev/null || echo "[]")
    echo "$to_create_rules" | jq -r '.[] | "- **\(._resourceType)** | \(._folder) | \(.title)"'
    echo ""
  fi

  if [[ "$delete_count" -gt 0 ]]; then
    echo "### Rules Deleted (Orphaned)"
    echo ""
    local to_delete_rules
    to_delete_rules=$(cat /tmp/gf_to_delete.json 2>/dev/null || echo "[]")
    echo "$to_delete_rules" | jq -r '.[] | "- \(.title) (folder: \(.folderUID))"'
    echo ""
  fi

  if [[ "$create_count" -eq 0 && "$delete_count" -eq 0 ]]; then
    echo "All rules are in sync. No changes needed."
  fi
}

case "${1:-}" in
  plan)    do_plan ;;
  apply)   do_apply ;;
  summary) do_summary ;;
  *)
    echo "Usage: $0 {plan|apply|summary}"
    echo ""
    echo "  plan    - Dry-run: compare expected vs existing, show diff"
    echo "  apply   - Apply changes to Grafana (create new, delete orphaned)"
    echo "  summary - Print markdown summary for GitHub step summary"
    exit 1
    ;;
esac
