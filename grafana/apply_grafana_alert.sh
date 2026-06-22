#!/usr/bin/env bash
set -u

export GRAFANA_URL="https://grafana-aca.credithome.com.tw"
export GRAFANA_ADMIN_USER="admin"
export GRAFANA_ADMIN_PASSWORD="password123"
export AZURE_DATASOURCE_UID="bf7jxviy4zksge"
# ============================================================
# 03_apply_grafana_alerts.sh
# [備用告警] 對所有 Prod App Service Plan 套用 Grafana Alert Rules
#
# ⚠️  定位：備用 / 二次告警
#     主要告警由 Azure Monitor (02_azure_monitor_alert_rules.sh) 負責
#     Grafana 告警僅在 Azure Monitor 漏報或 Azure Portal 不可用時補位
#
# 備用模式調整（相較主要告警）：
#   - Eval interval : 10m（主要 1m）→ 減少 Azure Monitor API 呼叫量
#   - Pending period: WARNING 90m / CRITICAL 45m（主要 60m/30m）→ 避免重複噪音
#   - Labels 加上 alert_source=grafana-backup，方便 routing 區分
#   - Notification Policy 建議路由到低優先度管道（e.g. Slack #alerts-backup）
#
# 依賴：
#   - az cli (已登入)
#   - jq, curl
#   - prod_asp.json（由 01_list_app_service_plans.sh 產生）
#   - scripts/02_grafana_alert_rules_template.json
#
# 使用方式：
#   export GRAFANA_URL="https://your-grafana.example.com"
#   export GRAFANA_TOKEN="glsa_xxxxxxxxxxxx"
#   export AZURE_DATASOURCE_UID="your-azure-monitor-ds-uid"
#   bash 03_apply_grafana_alerts.sh
# ============================================================

# ── 必要環境變數 ─────────────────────────────────────────────
: "${GRAFANA_URL:?請設定 GRAFANA_URL}"
: "${GRAFANA_ADMIN_USER:?請設定 GRAFANA_ADMIN_USER}"
: "${GRAFANA_ADMIN_PASSWORD:?請設定 GRAFANA_ADMIN_PASSWORD}"
: "${AZURE_DATASOURCE_UID:?請設定 AZURE_DATASOURCE_UID}"

GRAFANA_AUTH="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"

TEMPLATE_FILE="grafana_alert_rules_template.json"
PROD_ASP_FILE="804030.json"
FOLDER_TITLE="Backup-Alerts"
LOG_FILE="backup_alert_$(date +%Y%m%d_%H%M%S).log"

# ── 備用模式參數 ─────────────────────────────────────────────
BACKUP_INTERVAL="10m"          # group eval interval（主要為 1m）
BACKUP_WARN_PENDING="90m"      # warning pending（主要為 60m）
BACKUP_CRIT_PENDING="45m"      # critical pending（主要為 30m）
BACKUP_LABEL="alert_source=grafana-backup"

# ── SKU 頻寬/佇列上限 (與 02 保持一致) ──────────────────────
declare -A SKU_BANDWIDTH_BYTES_PER_MIN=(
  ["B1"]="781250000"   ["B2"]="781250000"   ["B3"]="781250000"
  ["S1"]="781250000"   ["S2"]="781250000"   ["S3"]="781250000"
  ["P1v2"]="1562500000" ["P2v2"]="3125000000" ["P3v2"]="6250000000"
  ["P1v3"]="1562500000" ["P2v3"]="3125000000" ["P3v3"]="6250000000"
  ["P0v3"]="781250000"
  ["EP1"]="1562500000" ["EP2"]="3125000000" ["EP3"]="6250000000"
  ["I1"]="781250000"   ["I2"]="1562500000"  ["I3"]="3125000000"
  ["I1v2"]="1562500000" ["I2v2"]="3125000000" ["I3v2"]="6250000000"
  ["DEFAULT"]="781250000"
)

# SocketOutboundEstablished 固定上限 128（Azure platform limit，與 SKU 無關）
SOCKET_MAX=1024

declare -A SKU_DISK_QUEUE_MAX=(
  ["B1"]="100" ["B2"]="200" ["B3"]="400"
  ["S1"]="100" ["S2"]="200" ["S3"]="400"
  ["P1v2"]="200" ["P2v2"]="400" ["P3v2"]="800"
  ["P1v3"]="200" ["P2v3"]="400" ["P3v3"]="800"
  ["DEFAULT"]="100"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2; }

calc_threshold() {
  echo "$1 $2" | awk '{printf "%.0f", $1 * $2 / 100}'
}

# ── Step 1: 確認 Grafana 連線 ────────────────────────────────
log "==> [備用模式] 確認 Grafana 連線: $GRAFANA_URL"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --user "$GRAFANA_AUTH" \
  "$GRAFANA_URL/api/health")

if [[ "$HTTP_STATUS" != "200" ]]; then
  err "Grafana 連線失敗 (HTTP $HTTP_STATUS)"
  exit 1
fi
log "    連線正常"

# ── Step 2: 建立或取得 Backup Alert Folder ───────────────────
log "==> 確認 Grafana Folder: $FOLDER_TITLE"
FOLDER_RESP=$(curl -s \
  --user "$GRAFANA_AUTH" \
  "$GRAFANA_URL/api/folders")

FOLDER_UID=$(echo "$FOLDER_RESP" | jq -r \
  --arg t "$FOLDER_TITLE" '.[] | select(.title==$t) | .uid')

if [[ -z "$FOLDER_UID" ]]; then
  log "    建立新 Folder..."
  FOLDER_CREATE_RESP=$(curl -s -X POST \
    --user "$GRAFANA_AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"$FOLDER_TITLE\"}" \
    "$GRAFANA_URL/api/folders")
  FOLDER_UID=$(echo "$FOLDER_CREATE_RESP" | jq -r '.uid // empty')
  if [[ -z "$FOLDER_UID" ]]; then
    err "Folder 建立失敗: $FOLDER_CREATE_RESP"
    exit 1
  fi
  log "    Folder UID: $FOLDER_UID"
else
  log "    既有 Folder UID: $FOLDER_UID"
fi

# ── Step 3: 讀取 prod ASP 清單 ───────────────────────────────
if [[ ! -f "$PROD_ASP_FILE" ]]; then
  err "找不到 $PROD_ASP_FILE，請先執行 01_list_app_service_plans.sh"
  exit 1
fi

PROD_COUNT=$(jq 'length' "$PROD_ASP_FILE")
log "==> 找到 $PROD_COUNT 個 Prod ASP，開始套用備用告警..."
log "    備用參數: interval=${BACKUP_INTERVAL} | warn_pending=${BACKUP_WARN_PENDING} | crit_pending=${BACKUP_CRIT_PENDING}"

SUCCESS=0
FAILED=0

# ── Step 4: 逐一套用備用 Alert Rules ────────────────────────
while IFS= read -r ASP; do
  ASP_NAME=$(echo "$ASP" | jq -r '.name')
  RG=$(echo "$ASP" | jq -r '.resourceGroup')
  SUB_ID=$(echo "$ASP" | jq -r '.subscriptionId')
  SKU=$(echo "$ASP" | jq -r '.sku // "DEFAULT"' | tr '[:lower:]' '[:upper:]')

  log ""
  log ">> $RG/$ASP_NAME (SKU: $SKU)"

  BW_MAX="${SKU_BANDWIDTH_BYTES_PER_MIN[$SKU]:-${SKU_BANDWIDTH_BYTES_PER_MIN[DEFAULT]}}"
  DISK_MAX="${SKU_DISK_QUEUE_MAX[$SKU]:-${SKU_DISK_QUEUE_MAX[DEFAULT]}}"

  # Network In — threshold 單位 Bytes（與 Azure Monitor 一致）
  NET_WARN=$(calc_threshold "$BW_MAX" 80)
  NET_CRIT=$(calc_threshold "$BW_MAX" 90)
  # SocketOutboundEstablished — 固定上限 128
  SOCK_OUT_WARN=$(calc_threshold "$SOCKET_MAX" 80)   # 102
  SOCK_OUT_CRIT=$(calc_threshold "$SOCKET_MAX" 90)   # 115
  DISK_WARN=$(calc_threshold "$DISK_MAX" 80)
  DISK_CRIT=$(calc_threshold "$DISK_MAX" 90)

  UID_PREFIX=$(echo "bk-${ASP_NAME}-${RG}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-22)

  # 讀取 template 並替換變數
  RULES_JSON=$(cat "$TEMPLATE_FILE" | \
    sed "s|\${AZURE_DATASOURCE_UID}|$AZURE_DATASOURCE_UID|g" | \
    sed "s|\${RESOURCE_GROUP}|$RG|g" | \
    sed "s|\${ASP_NAME}|$ASP_NAME|g" | \
    sed "s|\${RESOURCE_NAME}|$ASP_NAME|g" | \
    sed "s|\${SUBSCRIPTION_ID}|$SUB_ID|g" | \
    sed "s|\${NET_IN_WARN_BYTES}|$NET_WARN|g" | \
    sed "s|\${NET_IN_CRIT_BYTES}|$NET_CRIT|g" | \
    sed "s|\${NET_OUT_WARN_BYTES}|$NET_WARN|g" | \
    sed "s|\${NET_OUT_CRIT_BYTES}|$NET_CRIT|g" | \
    sed "s|\${SOCK_OUT_WARN}|$SOCK_OUT_WARN|g" | \
    sed "s|\${SOCK_OUT_CRIT}|$SOCK_OUT_CRIT|g" | \
    sed "s|\${DISK_WARN_THRESHOLD}|$DISK_WARN|g" | \
    sed "s|\${DISK_CRIT_THRESHOLD}|$DISK_CRIT|g")

  # ── 備用模式轉換：調整 interval / for / labels ────────────
  RULES_JSON=$(echo "$RULES_JSON" | jq \
    --arg interval "$BACKUP_INTERVAL" \
    --arg warn_for "$BACKUP_WARN_PENDING" \
    --arg crit_for "$BACKUP_CRIT_PENDING" \
    --arg prefix "$UID_PREFIX" \
    --arg src_label "grafana-backup" \
    '
    # .groups 是陣列
    [.groups[] |
      # 降低 group eval interval
      .interval = $interval |
      .rules = [.rules[] |
        # 依 severity 調整 pending period
        if .labels.severity == "warning"
        then .for = $warn_for
        else .for = $crit_for
        end |
        # 加上備用標籤
        .labels.alert_source = $src_label |
        .labels.alert_tier = "backup" |
        # 加上備用說明
        .annotations.backup_note = "[備用告警] 此規則為 Azure Monitor 的補位告警，eval 頻率已降低以減少重複通知" |
        # uid 加上 backup prefix 避免與主要告警衝突
        .uid = ($prefix + "-" + .uid | .[0:40]) |
        # params 內的字串數字轉回數字型別（sed 替換後為字串）
        # 只修改有 conditions 的 node（C/threshold），不動 B/A node
        .data = [.data[] |
          if (.model.conditions | length) > 0 then
            .model.conditions = [.model.conditions[] |
              .evaluator.params = [.evaluator.params[] |
                if type == "string" then tonumber else . end
              ]
            ]
          else
            .
          end
        ]
      ]
    ]
  ')

  # 逐條取出 rule，POST 到 Grafana Provisioning API
  # RULES_JSON 結構：[{interval, rules:[...]}, ...]
  # 先 flatten 成 rule 陣列，寫入暫存檔避免 read -r 在中文環境截斷問題
  RULES_TMP=$(mktemp /tmp/gf_rules_XXXXXX.json)
  echo "$RULES_JSON" | jq -c '[.[].rules[]]' > "$RULES_TMP"
  RULE_COUNT=$(jq 'length' "$RULES_TMP")
  RULE_INDEX=0

  log "    Rules 數量: $RULE_COUNT"

  while IFS= read -r RULE; do
    RULE_NAME=$(echo "$RULE" | jq -r '.title // .name // "unknown"')

    # Grafana provisioning alert-rule payload
    PAYLOAD=$(echo "$RULE" | jq \
      --arg folder_uid "$FOLDER_UID" \
      --arg rule_group "$ASP_NAME" \
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

    HTTP_CODE=$(curl -s -o /tmp/gf_resp.json -w "%{http_code}" \
      -X POST \
      --user "$GRAFANA_AUTH" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "$GRAFANA_URL/api/v1/provisioning/alert-rules")

    if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
      log "    [OK] $RULE_NAME"
    else
      err "    [FAIL] $RULE_NAME (HTTP $HTTP_CODE)"
      cat /tmp/gf_resp.json >> "$LOG_FILE" 2>/dev/null || true
      FAILED=$((FAILED+1))
    fi

    RULE_INDEX=$((RULE_INDEX+1))
  done < <(jq -c '.[]' "$RULES_TMP")

  rm -f "$RULES_TMP"

  SUCCESS=$((SUCCESS+1))
  log "   完成: $ASP_NAME"

done < <(jq -c '.[]' "$PROD_ASP_FILE")

# ── Step 5: 設定 Notification Policy（備用路由） ────────────
log ""
log "==> 提示：建議在 Grafana 設定獨立的 Notification Policy"
log "    Matchers: alert_source=grafana-backup, alert_tier=backup"
log "    路由到低優先度管道（如 Slack #alerts-backup）"
log "    避免與 Azure Monitor 告警產生重複通知"

# ── 結果摘要 ─────────────────────────────────────────────────
echo ""
log "============================================"
log " [備用告警] 套用完成"
log "   成功 ASP : $SUCCESS 個"
log "   失敗群組 : $FAILED 個"
log "   Folder   : $GRAFANA_URL/alerting/list"
log "   Log 檔案 : $LOG_FILE"
log ""
log " 備用模式參數 vs 主要告警 (Azure Monitor)："
log "   Eval interval : ${BACKUP_INTERVAL}     (主要: 5m)"
log "   Warn pending  : ${BACKUP_WARN_PENDING}    (主要: 60m)"
log "   Crit pending  : ${BACKUP_CRIT_PENDING}    (主要: 30m)"
log "   Label         : alert_source=grafana-backup"
log "============================================"
