#!/usr/bin/env bash
# ============================================================
# 00_reset_appplan_alerts.sh
# 清除所有 App Service Plan 的 Alert Rules，再重新建立
#
# 刪除策略：
#   不依賴 alert name 格式，直接對每個 ASP 組出 resource ID，
#   列出該 subscription 下 scopes 包含此 resource ID 的所有
#   metric alert，逐條刪除。
#   → 無論 02 的命名格式怎麼改，都能精準找到並刪除。
#
# 流程：
#   1. 讀取 prod_asp.json，對每個 ASP 組出 resource ID
#   2. az monitor metrics alert list --subscription，
#      jq 過濾 scopes[] 包含 resource ID 的 alert
#   3. 逐條 az monitor metrics alert delete
#   4. 全部清除後（非 --delete-only）呼叫 02 重新建立
#
# 使用方式：
#   bash 00_reset_appplan_alerts.sh               # 刪除 + 重建
#   bash 00_reset_appplan_alerts.sh --dry-run     # 只列出，不刪除
#   bash 00_reset_appplan_alerts.sh --delete-only # 只刪除，不重建
# ============================================================

set -u

PROD_ASP_FILE="prod_asp.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#REBUILD_SCRIPT="${SCRIPT_DIR}/azure_monitor_alert_rules.sh"
LOG_FILE="reset_alerts_$(date +%Y%m%d_%H%M%S).log"

DRY_RUN=false
DELETE_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --delete-only) DELETE_ONLY=true ;;
    *) echo "未知參數: $arg"; exit 1 ;;
  esac
done

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"        | tee -a "$LOG_FILE"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')]   [OK]   $*" | tee -a "$LOG_FILE"; }
skip() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]   [SKIP] $*" | tee -a "$LOG_FILE"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')]   [ERR]  $*" | tee -a "$LOG_FILE" >&2; }

# ── 前置檢查 ─────────────────────────────────────────────────
if [[ ! -f "$PROD_ASP_FILE" ]]; then
  err "找不到 $PROD_ASP_FILE，請先執行 list_app_service_plans.sh"
  exit 1
fi

#if [[ "$DRY_UN" == false && "$DELETE_ONLY" == false ]]; then
#  if [[ ! -f "$REBUILD_SCRIPT" ]]; then
#    err "找不到重建腳本 $REBUILD_SCRIPT"
#    exit 1
#  fi
#fi

# ── 列出該 ASP resource ID 對應的所有 alert ──────────────────
# az monitor metrics alert list 回傳整個 subscription 的 alert
# jq 過濾 scopes[] 中包含 resource_id（不分大小寫）的條目
# 輸出格式：alert_name<TAB>resource_group
list_alerts_by_scope() {
  local sub_id="$1"
  local resource_id_lower
  resource_id_lower=$(echo "$2" | tr '[:upper:]' '[:lower:]')

  az monitor metrics alert list \
    --subscription "$sub_id" \
    --query "[].{name:name, rg:resourceGroup, scopes:scopes}" \
    -o json 2>/dev/null \
  | jq -r \
    --arg rid "$resource_id_lower" \
    '.[] | select(.scopes[] | ascii_downcase | contains($rid)) | "\(.name)\t\(.rg)"'
}

# ── 刪除單條 alert ───────────────────────────────────────────
# return 0 = 成功（含 404 不存在）
# return 1 = 真正的刪除失敗
delete_alert() {
  local name="$1"
  local rg="$2"
  local sub_id="$3"

  if [[ "$DRY_RUN" == true ]]; then
    log "  [DRY-RUN] 將刪除: $name (RG: $rg)"
    return 0
  fi

  local stderr_out
  if stderr_out=$(az monitor metrics alert delete \
      --name "$name" \
      --resource-group "$rg" \
      --subscription "$sub_id" \
      2>&1); then
    ok "已刪除: $name"
    return 0
  else
    if echo "$stderr_out" | grep -qi "ResourceNotFound\|not found\|404"; then
      skip "不存在（已清除）: $name"
      return 0
    fi
    err "刪除失敗: $name"
    err "  原因: $stderr_out"
    return 1
  fi
}

# ── 主流程 ───────────────────────────────────────────────────
PROD_COUNT=$(jq 'length' "$PROD_ASP_FILE")
TOTAL_DELETED=0
TOTAL_FAILED=0

log "=========================================="
log "STEP 1：清除舊 Alert Rules"
[[ "$DRY_RUN"     == true ]] && log "  *** DRY-RUN 模式：不實際刪除 ***"
[[ "$DELETE_ONLY" == true ]] && log "  *** DELETE-ONLY 模式：完成後不重建 ***"
log "  共 $PROD_COUNT 個 Prod ASP"
log "=========================================="

IDX=0
while IFS= read -r ASP; do
  IDX=$((IDX + 1))
  ASP_NAME=$(echo "$ASP" | jq -r '.name')
  RG=$(echo "$ASP"       | jq -r '.resourceGroup')
  SUB_ID=$(echo "$ASP"   | jq -r '.subscriptionId')

  # 組出標準 resource ID（小寫比對用）
  RESOURCE_ID="/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.Web/serverfarms/${ASP_NAME}"

  log ""
  log "[$IDX/$PROD_COUNT] $ASP_NAME (RG: $RG)"

  # 列出 scope 指向此 ASP 的所有 alert（name<TAB>rg）
  MATCHED=$(list_alerts_by_scope "$SUB_ID" "$RESOURCE_ID" || true)

  if [[ -z "$MATCHED" ]]; then
    log "  (無對應 Alert Rules，略過)"
    continue
  fi

  # 印出將刪除的清單
  MATCH_COUNT=$(echo "$MATCHED" | wc -l | tr -d ' ')
  log "  找到 $MATCH_COUNT 條 Alert Rules"

  COUNT=0
  FAIL=0
  while IFS=$'\t' read -r alert_name alert_rg; do
    [[ -z "$alert_name" ]] && continue
    if delete_alert "$alert_name" "$alert_rg" "$SUB_ID"; then
      COUNT=$((COUNT + 1))
      TOTAL_DELETED=$((TOTAL_DELETED + 1))
    else
      FAIL=$((FAIL + 1))
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
  done <<< "$MATCHED"

  log "  完成 $ASP_NAME：刪除 $COUNT 條，失敗 $FAIL 條"

done < <(jq -c '.[]' "$PROD_ASP_FILE")

log ""
log "=========================================="
log "STEP 1 完成"
log "  刪除成功: $TOTAL_DELETED 條"
log "  刪除失敗: $TOTAL_FAILED 條"
log "=========================================="

if [[ "$TOTAL_FAILED" -gt 0 ]]; then
  err "有 $TOTAL_FAILED 條刪除失敗，請檢查 log，中止重建。"
  exit 1
fi

## ── STEP 2：重建 ──────────────────────────────────────────────
#if [[ "$DRY_RUN" == true ]]; then
#  log ""
#  log "DRY-RUN 模式：略過重建步驟"
#  exit 0
#fi
#
#if [[ "$DELETE_ONLY" == true ]]; then
#  log ""
#  log "DELETE-ONLY 模式：略過重建步驟"
#  exit 0
#fi
#
#log ""
#log "=========================================="
#log "STEP 2：重新建立 Alert Rules"
#log "=========================================="
#bash "$REBUILD_SCRIPT"

log ""
log "=========================================="
log "全部完成 | Log: $LOG_FILE"
log "=========================================="
