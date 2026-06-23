#!/usr/bin/env bash
# ============================================================
# discover_resources.sh
# Unified resource discovery: App Service Plan + Redis + SQL Server
# Output: inventory.json
#
# Usage:
#   bash discover_resources.sh                          # use current az login subscription
#   bash discover_resources.sh --output my_inv.json     # custom output file
#   bash discover_resources.sh --subscription <id>      # specific subscription
# ============================================================
set -u

OUTPUT_FILE="inventory.json"
TARGET_SUBSCRIPTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --subscription) TARGET_SUBSCRIPTION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAPPING_FILE="${PROJECT_ROOT}/config/project_mapping.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

resolve_project() {
  local rg="$1"
  local res_name="$2"
  local sub_id="$3"

  if [[ ! -f "$MAPPING_FILE" ]]; then
    echo "$rg"
    return
  fi

  local project
  project=$(jq -r --arg rg "$rg" --arg name "$res_name" --arg sub "$sub_id" '
    .mappings[] as $m |
    select($m.resourceGroup == $rg) |
    if $m.resourceNamePattern then
      if ($name | test($m.resourceNamePattern; "i")) then $m.project else empty end
    else
      $m.project
    end
  ' "$MAPPING_FILE" | head -1)

  if [[ -n "$project" ]]; then
    echo "$project"
  else
    echo "$rg"
  fi
}

is_prod_resource() {
  local name="$1"
  local rg="$2"
  local tags_json="$3"

  local combined="${name} ${rg} ${tags_json}"
  if echo "$combined" | grep -qiE 'prod|pro|production|正式機|正式'; then
    return 0
  fi
  return 1
}

discover_asp() {
  local sub_id="$1"
  local sub_name="$2"
  log "  Discovering App Service Plans..."

  local plans
  plans=$(az appservice plan list \
    --subscription "$sub_id" \
    --query "[].{name:name, resourceGroup:resourceGroup, location:location, sku:sku.name, tier:sku.tier, capacity:sku.capacity, tags:tags}" \
    -o json 2>/dev/null || echo "[]")

  local count
  count=$(echo "$plans" | jq 'length')
  log "    Found $count ASPs total"

  echo "$plans" | jq -c --arg sub_id "$sub_id" --arg sub_name "$sub_name" '
    [.[] |
     select(
       (.name | test("prod|pro|production|ai|aiservice|taogefu|taoge|crossplat"; "i")) or
       (.name | test("正式機|正式")) or
       (.resourceGroup | test("prod|pro|production|ai|aiservice|taogefu|taoge|crossplat"; "i")) or
       (.resourceGroup | test("正式機|正式"))
     ) |
     select(.name | test("測試|test|Pi|PiEncr") | not) |
     {
       type: "AppServicePlan",
       name: .name,
       resourceGroup: .resourceGroup,
       location: .location,
       sku: .sku,
       tier: .tier,
       capacity: .capacity,
       subscriptionId: $sub_id,
       subscriptionName: $sub_name
     }
    ]'
}

discover_redis() {
  local sub_id="$1"
  local sub_name="$2"
  log "  Discovering Redis caches..."

  local caches
  caches=$(az redis list \
    --subscription "$sub_id" \
    --query "[].{name:name, resourceGroup:resourceGroup, location:location, sku:sku.name, capacity:sku.capacity, provisioningState:provisioningState, tags:tags}" \
    -o json 2>/dev/null || echo "[]")

  local count
  count=$(echo "$caches" | jq 'length')
  log "    Found $count Redis caches total"

  echo "$caches" | jq -c --arg sub_id "$sub_id" --arg sub_name "$sub_name" '
    [.[] |
     select(.provisioningState == "Succeeded") |
     select(
       (.name | test("prod|pro|production"; "i")) or
       (.name | test("正式機|正式")) or
       (.resourceGroup | test("prod|pro|production"; "i")) or
       (.resourceGroup | test("正式機|正式"))
     ) |
     {
       type: "Redis",
       name: .name,
       resourceGroup: .resourceGroup,
       location: .location,
       sku: .sku,
       capacity: .capacity,
       subscriptionId: $sub_id,
       subscriptionName: $sub_name
     }
    ]'
}

discover_elastic_pool() {
  local sub_id="$1"
  local sub_name="$2"
  log "  Discovering SQL Elastic Pools..."

  local servers
  servers=$(az sql server list \
    --subscription "$sub_id" \
    --query "[?state=='Ready'].{name:name, resourceGroup:resourceGroup}" \
    -o json 2>/dev/null || echo "[]")

  local pools_json="[]"
  while IFS= read -r server; do
    local srv_name srv_rg
    srv_name=$(echo "$server" | jq -r '.name')
    srv_rg=$(echo "$server" | jq -r '.resourceGroup')

    local pools
    pools=$(az sql elastic-pool list \
      --server "$srv_name" \
      --resource-group "$srv_rg" \
      --subscription "$sub_id" \
      --query "[?state=='Ready'].{name:name, location:location, sku:sku.name, tier:sku.tier, capacity:sku.capacity, serverName: '${srv_name}'}" \
      -o json 2>/dev/null || echo "[]")

    local filtered
    filtered=$(echo "$pools" | jq -c --arg sub_id "$sub_id" --arg sub_name "$sub_name" --arg srv_rg "$srv_rg" '
      [.[] |
       select(
         (.name | test("prod|pro|production"; "i")) or
         (.name | test("正式機|正式")) or
         ($srv_rg | test("prod|pro|production"; "i")) or
         ($srv_rg | test("正式機|正式"))
       ) |
       {
         type: "SQLElasticPool",
         name: .name,
         serverName: .serverName,
         resourceGroup: $srv_rg,
         location: .location,
         sku: .sku,
         tier: .tier,
         capacity: .capacity,
         subscriptionId: $sub_id,
         subscriptionName: $sub_name
       }
     ]')

    pools_json=$(echo "$pools_json" "$filtered" | jq -s 'add')
  done < <(echo "$servers" | jq -c '.[]')

  local count
  count=$(echo "$pools_json" | jq 'length')
  log "    Found $count Elastic Pools total"

  echo "$pools_json"
}

main() {
  log "==> Resource Discovery Start"

  local subscriptions
  if [[ -n "$TARGET_SUBSCRIPTION" ]]; then
    subscriptions=$(az account list --query "[?id=='$TARGET_SUBSCRIPTION'].{id:id, name:name}" -o json)
  else
    subscriptions=$(az account list --query "[].{id:id, name:name}" -o json)
  fi

  local sub_count
  sub_count=$(echo "$subscriptions" | jq 'length')
  log "  Subscriptions: $sub_count"

  local all_resources="[]"

  while IFS= read -r sub_id; do
    local sub_name
    sub_name=$(echo "$subscriptions" | jq -r --arg id "$sub_id" '.[] | select(.id==$id) | .name')
    log "  Processing: $sub_name ($sub_id)"

    local asp_json redis_json pool_json
    asp_json=$(discover_asp "$sub_id" "$sub_name")
    redis_json=$(discover_redis "$sub_id" "$sub_name")
    pool_json=$(discover_elastic_pool "$sub_id" "$sub_name")

    local merged
    merged=$(echo "$asp_json" "$redis_json" "$pool_json" | jq -s 'add')
    all_resources=$(echo "$all_resources" "$merged" | jq -s 'add')
  done < <(echo "$subscriptions" | jq -r '.[].id')

  local total
  total=$(echo "$all_resources" | jq 'length')
  log "  Total resources discovered: $total"

  local asp_count redis_count pool_count
  asp_count=$(echo "$all_resources" | jq '[.[] | select(.type=="AppServicePlan")] | length')
  redis_count=$(echo "$all_resources" | jq '[.[] | select(.type=="Redis")] | length')
  pool_count=$(echo "$all_resources" | jq '[.[] | select(.type=="SQLElasticPool")] | length')
  log "  ASP: $asp_count | Redis: $redis_count | ElasticPool: $pool_count"

  log "  Resolving project mappings..."
  all_resources=$(echo "$all_resources" | jq -c '
    [.[] | . + {project: ""}]
  ')

  local final_json="[]"
  while IFS= read -r res; do
    local rg name sub_id project
    rg=$(echo "$res" | jq -r '.resourceGroup')
    name=$(echo "$res" | jq -r '.name')
    sub_id=$(echo "$res" | jq -r '.subscriptionId')
    project=$(resolve_project "$rg" "$name" "$sub_id")
    local updated
    updated=$(echo "$res" | jq -c --arg p "$project" '.project = $p')
    final_json=$(echo "$final_json" | jq -c --argjson obj "$updated" '. + [$obj]')
  done < <(echo "$all_resources" | jq -c '.[]')

  echo "$final_json" | jq '.' > "$OUTPUT_FILE"
  log "==> Saved to $OUTPUT_FILE"

  echo ""
  echo "============================================"
  echo " Discovery Summary"
  echo "============================================"
  echo "$final_json" | jq -r '.[] | "  [\(.type)] \(.project) / \(.resourceGroup) / \(.name)"'
  echo "============================================"
  echo " Total: $total resources → $OUTPUT_FILE"
}

main
