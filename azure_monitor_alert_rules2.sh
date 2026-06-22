#!/usr/bin/env bash
# ============================================================
# 02_azure_monitor_alert_rules.sh
# 對所有 Prod App Service Plan 套用 Azure Monitor Alert Rules
#
# 告警規則：
#   WARNING  : 60min 內平均值 > 80%
#   CRITICAL : 30min 內平均值 > 90%
#
# 指標（共 5 種，每種 2 條，每個 ASP 共 10 條）：
#   CPU / Memory / DiskQueue / Network In (BytesReceived) /
#   Established Socket Count for Outbound Requests (SocketOutboundEstablished)
#
# Network 閾值單位：MB/min（依 SKU 頻寬換算）
# Socket 閾值：動態計算 = instance_count * 1024（每 instance 上限 1024）
#
# Alert 命名格式：Alert-{asp_name}-{metric}-{severity}
#
# 依賴：
#   - az cli (已登入，需有 Contributor 或 Monitoring Contributor 角色)
#   - jq
#   - 01_list_app_service_plans.sh 產生的 prod_asp.json
#   - 05_clone_action_group.sh 已將 "Action Send Alert" 複製到各 subscription
#
# 使用方式：
#   bash 02_azure_monitor_alert_rules.sh
# ============================================================

set -u

#PROD_ASP_FILE="prod_asp.json"
PROD_ASP_FILE="prod_3.json"
LOG_FILE="azure_alert_apply_$(date +%Y%m%d_%H%M%S).log"

ACTION_GROUP_NAME="Action Send Alert"

# Azure App Service 每個 instance outbound established socket 安全上限（per instance）
SOCKET_PER_INSTANCE=1024

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2; }

# ── 前置檢查 ─────────────────────────────────────────────────
if [[ ! -f "$PROD_ASP_FILE" ]]; then
  err "找不到 $PROD_ASP_FILE，請先執行 list_app_service_plans.sh"
  exit 1
fi

# ── 動態查找 Action Group ID（依 subscription） ───────────────
get_action_group_id() {
  local sub_id="$1"
  local rg="$2"
  local ag_id

  ag_id=$(az monitor action-group show \
    --name "$ACTION_GROUP_NAME" \
    --resource-group "$rg" \
    --subscription "$sub_id" \
    --query "id" -o tsv 2>/dev/null || echo "")

  if [[ -n "$ag_id" ]]; then
    echo "$ag_id"
    return 0
  fi

  # 同 subscription 其他 RG
  ag_id=$(az monitor action-group list \
    --subscription "$sub_id" \
    --query "[?name=='$ACTION_GROUP_NAME'].id | [0]" -o tsv 2>/dev/null || echo "")

  echo "$ag_id"
}

# ── 動態查詢 ASP instance 數量 ────────────────────────────────
# 回傳當前設定的 capacity（scale out 數量），至少為 1
get_instance_count() {
  local sub_id="$1"
  local rg="$2"
  local asp_name="$3"
  local count

  count=$(az appservice plan show \
    --name "$asp_name" \
    --resource-group "$rg" \
    --subscription "$sub_id" \
    --query "sku.capacity" -o tsv 2>/dev/null || echo "")

  # 若查詢失敗或為空，預設 1
  if [[ -z "$count" || "$count" -lt 1 ]]; then
    echo "1"
  else
    echo "$count"
  fi
}

log "Action Group 名稱: \"$ACTION_GROUP_NAME\""
log "（將依每個 ASP 的 subscription 動態查找 Action Group ID）"

# ── SKU 頻寬上限對照表 (Bytes/min) ───────────────────────────
declare -A SKU_BW_BYTES_MIN
SKU_BW_BYTES_MIN["B1"]="786432000"
SKU_BW_BYTES_MIN["B2"]="786432000"
SKU_BW_BYTES_MIN["B3"]="786432000"
SKU_BW_BYTES_MIN["S1"]="786432000"
SKU_BW_BYTES_MIN["S2"]="786432000"
SKU_BW_BYTES_MIN["S3"]="786432000"
SKU_BW_BYTES_MIN["P1v2"]="1572864000"
SKU_BW_BYTES_MIN["P2v2"]="3145728000"
SKU_BW_BYTES_MIN["P3v2"]="6291456000"
SKU_BW_BYTES_MIN["P1v3"]="1572864000"
SKU_BW_BYTES_MIN["P2v3"]="3145728000"
SKU_BW_BYTES_MIN["P3v3"]="6291456000"
SKU_BW_BYTES_MIN["P0v3"]="786432000"
SKU_BW_BYTES_MIN["EP1"]="1572864000"
SKU_BW_BYTES_MIN["EP2"]="3145728000"
SKU_BW_BYTES_MIN["EP3"]="6291456000"
SKU_BW_BYTES_MIN["I1"]="786432000"
SKU_BW_BYTES_MIN["I1v2"]="1572864000"
SKU_BW_BYTES_MIN["I2"]="1572864000"
SKU_BW_BYTES_MIN["I2v2"]="3145728000"
SKU_BW_BYTES_MIN["I3"]="3145728000"
SKU_BW_BYTES_MIN["I3v2"]="6291456000"
SKU_BW_BYTES_MIN["DEFAULT"]="786432000"

declare -A SKU_BW_MB_MIN
SKU_BW_MB_MIN["B1"]="750"
SKU_BW_MB_MIN["B2"]="750"    SKU_BW_MB_MIN["B3"]="750"
SKU_BW_MB_MIN["S1"]="750"    SKU_BW_MB_MIN["S2"]="750"    SKU_BW_MB_MIN["S3"]="750"
SKU_BW_MB_MIN["P1v2"]="1500" SKU_BW_MB_MIN["P2v2"]="3000" SKU_BW_MB_MIN["P3v2"]="6000"
SKU_BW_MB_MIN["P1v3"]="1500" SKU_BW_MB_MIN["P2v3"]="3000" SKU_BW_MB_MIN["P3v3"]="6000"
SKU_BW_MB_MIN["P0v3"]="750"
SKU_BW_MB_MIN["EP1"]="1500"  SKU_BW_MB_MIN["EP2"]="3000"  SKU_BW_MB_MIN["EP3"]="6000"
SKU_BW_MB_MIN["I1"]="750"    SKU_BW_MB_MIN["I1v2"]="1500"
SKU_BW_MB_MIN["I2"]="1500"   SKU_BW_MB_MIN["I2v2"]="3000"
SKU_BW_MB_MIN["I3"]="3000"   SKU_BW_MB_MIN["I3v2"]="6000"
SKU_BW_MB_MIN["DEFAULT"]="750"

# ── 計算閾值 ────────────────────────────────────────────────
calc_threshold() {
  local base=$1
  local pct=$2
  echo "$base $pct" | awk '{printf "%.0f", $1 * $2 / 100}'
}

# ── 建立單一 Azure Monitor Metric Alert ─────────────────────
create_alert() {
  local rule_name="$1"
  local resource_id="$2"
  local metric="$3"
  local threshold="$4"
  local window_min="$5"
  local severity="$6"
  local action_group_id="$7"
  local subscription_id="$8"
  local resource_group="$9"
  local description="${10}"
  local unit="${11:-Percent}"

  local window="PT${window_min}M"
  local freq="PT5M"

  local existing
  existing=$(az monitor metrics alert show \
    --name "$rule_name" \
    --resource-group "$resource_group" \
    --subscription "$subscription_id" \
    --query "name" -o tsv 2>/dev/null || echo "")

  if [[ -n "$existing" ]]; then
    log "    [SKIP] 已存在: $rule_name"
    SKIPPED=$((SKIPPED+1))
    return 0
  fi

  if az monitor metrics alert create \
    --name "$rule_name" \
    --resource-group "$resource_group" \
    --subscription "$subscription_id" \
    --scopes "$resource_id" \
    --condition "avg ${metric} > ${threshold}" \
    --window-size "$window" \
    --evaluation-frequency "$freq" \
    --severity "$severity" \
    --description "$description" \
    --action "$action_group_id" \
    --tags "environment=prod" "managed-by=nebula-automation" \
    --output none; then
    log "    [OK] Alert--------${rule_name##*Alert-} (${window_min}min > ${threshold} ${unit}, severity=${severity})"
    SUCCESS=$((SUCCESS+1))
  else
    err "    [FAIL] $rule_name"
    FAILED=$((FAILED+1))
  fi
}

# ── 主流程 ──────────────────────────────────────────────────
PROD_COUNT=$(jq 'length' "$PROD_ASP_FILE")

log "============================================"
log " Azure Monitor Alert Rules - Prod ASP"
log " ASP 數量    : $PROD_COUNT"
log " Action Group: $ACTION_GROUP_NAME"
log "              (依各 ASP subscription 動態查找)"
log " 規則        : WARNING(80%/60min) + CRITICAL(90%/30min)"
log " Network 指標: BytesReceived (Data In) only, 單位 MB"
log " Socket 指標 : SocketOutboundEstablished, 動態 = instance數 × $SOCKET_PER_INSTANCE"
log "============================================"

SUCCESS=0
FAILED=0
SKIPPED=0

while IFS= read -r ASP; do
  ASP_NAME=$(echo "$ASP" | jq -r '.name')
  RG=$(echo "$ASP" | jq -r '.resourceGroup')
  SUB_ID=$(echo "$ASP" | jq -r '.subscriptionId')
  SKU=$(echo "$ASP" | jq -r '.sku // "DEFAULT"' | tr '[:lower:]' '[:upper:]')

  RESOURCE_ID="/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Web/serverfarms/${ASP_NAME}"

  BW_MAX_BYTES="${SKU_BW_BYTES_MIN[$SKU]:-${SKU_BW_BYTES_MIN[DEFAULT]}}"
  BW_MAX_MB="${SKU_BW_MB_MIN[$SKU]:-${SKU_BW_MB_MIN[DEFAULT]}}"

  # ── 動態查詢 instance 數，計算 socket 上限 ──────────────────
  INSTANCE_COUNT=$(get_instance_count "$SUB_ID" "$RG" "$ASP_NAME")
  SOCKET_MAX=$((INSTANCE_COUNT * SOCKET_PER_INSTANCE))

  log ""
  log ">> [$SUB_ID] $RG/$ASP_NAME (SKU: $SKU)"
  log "   BW_MAX: ${BW_MAX_MB} MB/min (${BW_MAX_BYTES} Bytes/min) | Socket MAX: ${SOCKET_MAX} (${INSTANCE_COUNT} instance × ${SOCKET_PER_INSTANCE})"

  # 依 ASP 的 subscription 動態查找 Action Group ID
  ACTION_GROUP_ID=$(get_action_group_id "$SUB_ID" "$RG")
  if [[ -z "$ACTION_GROUP_ID" ]]; then
    err "   找不到 Action Group \"$ACTION_GROUP_NAME\" 於 subscription $SUB_ID"
    err "   請先執行 05_clone_action_group.sh 將 Action Group 複製到此 subscription"
    FAILED=$((FAILED+10))
    continue
  fi
  log "   Action Group: $ACTION_GROUP_ID"

  # 計算各指標閾值
  NET_WARN_BYTES=$(calc_threshold "$BW_MAX_BYTES" 80)
  NET_CRIT_BYTES=$(calc_threshold "$BW_MAX_BYTES" 90)
  NET_WARN_MB=$(calc_threshold "$BW_MAX_MB" 80)
  NET_CRIT_MB=$(calc_threshold "$BW_MAX_MB" 90)
  SOCK_WARN=$(calc_threshold "$SOCKET_MAX" 80)
  SOCK_CRIT=$(calc_threshold "$SOCKET_MAX" 90)

  # Alert name prefix：Alert-{readable}-{hash8}
  ASP_HASH=$(echo -n "${ASP_NAME}" | md5sum | cut -c1-8)
  ASP_READABLE=$(echo "${ASP_NAME}" | tr '[:upper:]' '[:lower:]' | \
    iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || echo "${ASP_NAME}" | tr '[:upper:]' '[:lower:]')
  ASP_READABLE=$(echo "${ASP_READABLE}" | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//' | cut -c1-40)
  [[ -z "${ASP_READABLE}" ]] && ASP_READABLE="alert"
  ASP_SLUG="${ASP_READABLE}"
#  PREFIX="Alert-${ASP_SLUG}"
  PREFIX="${ASP_SLUG}"

  # ── CPU ──────────────────────────────────────────────────
  create_alert \
    "CPU-warn-over80-${PREFIX}" "$RESOURCE_ID" \
    "CpuPercentage" "80" \
    "15" "2" "$ACTION_GROUP_ID" \
    "$SUB_ID" "$RG" \
    "[WARNING] $ASP_NAME CPU > 80% (60min avg)" "Percent"

  create_alert \
    "CPU-crit-over90-${PREFIX}" "$RESOURCE_ID" \
    "CpuPercentage" "90" \
    "30" "1" "$ACTION_GROUP_ID" \
    "$SUB_ID" "$RG" \
    "[CRITICAL] $ASP_NAME CPU > 90% (30min avg)" "Percent"

  # ── Memory ───────────────────────────────────────────────
  create_alert \
    "MEMORY-warn-over80-${PREFIX}" "$RESOURCE_ID" \
    "MemoryPercentage" "80" \
    "15" "2" "$ACTION_GROUP_ID" \
    "$SUB_ID" "$RG" \
    "[WARNING] $ASP_NAME Memory > 80% (60min avg)" "Percent"

  create_alert \
    "MEMORY-crit-over90-${PREFIX}" "$RESOURCE_ID" \
    "MemoryPercentage" "90" \
    "30" "1" "$ACTION_GROUP_ID" \
    "$SUB_ID" "$RG" \
    "[CRITICAL] $ASP_NAME Memory > 90% (30min avg)" "Percent"

  # ── DiskQueue ────────────────────────────────────────────
  create_alert \
    "DISK-warn-over80-${PREFIX}" "$RESOURCE_ID" \
    "DiskQueueLength" "80" \
    "15" "2" "$ACTION_GROUP_ID" \
    "$SUB_ID" "$RG" \
    "[WARNING] $ASP_NAME DiskQueue > 80 (60min avg)" "Count"

  create_alert \
    "DISK-crit-over90-${PREFIX}" "$RESOURCE_ID" \
    "DiskQueueLength" "90" \
    "30" "1" "$ACTION_GROUP_ID" \
    "$SUB_ID" "$RG" \
    "[CRITICAL] $ASP_NAME DiskQueue > 90 (30min avg)" "Count"

#  # ── Network In (BytesReceived) ────────────────────────────
#  create_alert \
#    "NETWORK-Inbond-warn-over80-${PREFIX}" "$RESOURCE_ID" \
#    "BytesReceived" "$NET_WARN_BYTES" \
#    "15" "2" "$ACTION_GROUP_ID" \
#    "$SUB_ID" "$RG" \
#    "[WARNING] $ASP_NAME Network In > ${NET_WARN_MB} MB/min (80% BW, 60min avg)" "Bytes"
#
#  create_alert \
#    "NETWORK-Inbond-crit-over90-${PREFIX}" "$RESOURCE_ID" \
#    "BytesReceived" "$NET_CRIT_BYTES" \
#    "30" "1" "$ACTION_GROUP_ID" \
#    "$SUB_ID" "$RG" \
#    "[CRITICAL] $ASP_NAME Network In > ${NET_CRIT_MB} MB/min (90% BW, 30min avg)" "Bytes"

  # ── Outbound Established Sockets（動態閾值）──────────────
  # SOCKET_MAX = instance_count × 1024（每 instance 上限）
  # WARN = SOCKET_MAX × 80%，視窗 60min
  # CRIT = SOCKET_MAX × 90%，視窗 30min
#  create_alert \
#    "NETWORK-Socket-warn-over80-${PREFIX}" "$RESOURCE_ID" \
#    "SocketOutboundEstablished" "$SOCK_WARN" \
#    "15" "2" "$ACTION_GROUP_ID" \
#    "$SUB_ID" "$RG" \
#    "[WARNING] $ASP_NAME Outbound Sockets > ${SOCK_WARN} (80% of ${SOCKET_MAX} = ${INSTANCE_COUNT}×${SOCKET_PER_INSTANCE}, 60min avg)" "Count"

  create_alert \
    "NETWORK-Socket-crit-over90-${PREFIX}" "$RESOURCE_ID" \
    "SocketOutboundEstablished" "$SOCK_CRIT" \
    "30" "1" "$ACTION_GROUP_ID" \
    "$SUB_ID" "$RG" \
    "[CRITICAL] $ASP_NAME Outbound Sockets > ${SOCK_CRIT} (90% of ${SOCKET_MAX} = ${INSTANCE_COUNT}×${SOCKET_PER_INSTANCE}, 30min avg)" "Count"

  log "   完成 $ASP_NAME：共 10 條 Alert Rules"

done < <(jq -c '.[]' "$PROD_ASP_FILE")

# ── 摘要 ────────────────────────────────────────────────────
echo ""
log "============================================"
log " 結果摘要"
log "   成功建立   : $SUCCESS 條"
log "   略過(已存在): $SKIPPED 條"
log "   失敗       : $FAILED 條"
log "   Log 檔案   : $LOG_FILE"
log ""
log " 每個 ASP 建立的 Alert Rules (10 條)："
log "   CPU warn/crit | Memory warn/crit | DiskQueue warn/crit"
log "   Network In (BytesReceived) warn/crit"
log "   Outbound Established Sockets (動態 instance數×1024) warn/crit"
log "============================================"
