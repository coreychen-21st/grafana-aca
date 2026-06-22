#!/usr/bin/env bash
# ============================================================
# 05_clone_action_group.sh
# 將 "Action Send Alert" Action Group 複製到其他 subscription
#
# 來源：
#   subscription : c9f80f0b-7d34-4410-a79c-ca23fb550d20
#   resource group: 廿一世紀數位科技股份有限公司
#
# 目標（跨 subscription，各自的 RG）：
#   subscription : fc6b18ca-199c-4123-8097-834cfc7ac213
#     RG 1: 分期趣正式機
#     RG 2: FanPay正式機
#
# 使用方式：
#   bash 05_clone_action_group.sh
# ============================================================

set -u

LOG_FILE="clone_action_group_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2; }

# ── 設定 ─────────────────────────────────────────────────────
AG_NAME="Action Send Alert"
AG_SHORT_NAME="Send Alert"    # groupShortName 最多 12 字元
AG_LOCATION="Global"

SRC_SUB="c9f80f0b-7d34-4410-a79c-ca23fb550d20"
SRC_RG="廿一世紀數位科技股份有限公司"

DST_SUB="fc6b18ca-199c-4123-8097-834cfc7ac213"
DST_RGS=(
  "分期趣正式機"
  "FanPay正式機"
)

# ── Receivers（從來源 Action Group 抄錄） ────────────────────
# Azure App Push (3)
APP_PUSH_ARGS=(
  --action azureapppush  "Send Alert to Ken_-AzureAppAction-"   yokisei@gmail.com
  --action azureapppush  "Send Alert to Tom_-AzureAppAction-"   tom200e@hotmail.com
  --action azureapppush  "Send Alert to Corey_-AzureAppAction-" corey_chen@happyfan7.com
)

# Email (6)
EMAIL_ARGS=(
  --action email  "Send Alert to Nab_-EmailAction-"   nab_lu@happyfan7.com
  --action email  "Send Alert to Jeff_-EmailAction-"  jeff_ma@happyfan7.com
  --action email  "Send Alert to Dirk_-EmailAction-"  dirk_huang@happyfan7.com
  --action email  "Send Alert to Ken_-EmailAction-"   yokisei@gmail.com
  --action email  "Send Alert to Tom_-EmailAction-"   tom200e@hotmail.com
  --action email  "Send Alert to Corey_-EmailAction-" corey_chen@happyfan7.com
)

# SMS (4) — 格式: countryCode-phoneNumber
SMS_ARGS=(
  --action sms  "Send Alert to Jeff_-SMSAction-"  886  982975589
  --action sms  "Send Alert to Dirk_-SMSAction-"  886  955786368
  --action sms  "Send Alert to Ken_-SMSAction-"   886  921926818
  --action sms  "Send Alert to Corey_-SMSAction-" 886  968621720
)

# ── 主流程 ────────────────────────────────────────────────────
log "============================================"
log " Clone Action Group: \"$AG_NAME\""
log " 來源: [$SRC_SUB] $SRC_RG"
log " 目標 Subscription: $DST_SUB"
log " 目標 RG 數量: ${#DST_RGS[@]}"
log "============================================"

SUCCESS=0
FAILED=0

for DST_RG in "${DST_RGS[@]}"; do
  log ""
  log ">> 目標 RG: $DST_RG"

  # 檢查是否已存在
  EXISTING=$(az monitor action-group show \
    --name "$AG_NAME" \
    --resource-group "$DST_RG" \
    --subscription "$DST_SUB" \
    --query "name" -o tsv 2>/dev/null || echo "")

  if [[ -n "$EXISTING" ]]; then
    log "   [SKIP] 已存在: $AG_NAME (RG: $DST_RG)"
    (( SUCCESS++ )) || true
    continue
  fi

  # 建立 Action Group
  # az monitor action-group create 的 --action 格式：
  #   email    <name> <email>
  #   sms      <name> <countryCode> <phoneNumber>
  #   azureapppush <name> <email>
  if az monitor action-group create \
    --name "$AG_NAME" \
    --resource-group "$DST_RG" \
    --subscription "$DST_SUB" \
    --short-name "$AG_SHORT_NAME" \
    --location "$AG_LOCATION" \
    --action azureapppush "Send Alert to Ken_-AzureAppAction-"   yokisei@gmail.com \
    --action azureapppush "Send Alert to Tom_-AzureAppAction-"   tom200e@hotmail.com \
    --action azureapppush "Send Alert to Corey_-AzureAppAction-" corey_chen@happyfan7.com \
    --action email "Send Alert to Nab_-EmailAction-"   nab_lu@happyfan7.com \
    --action email "Send Alert to Jeff_-EmailAction-"  jeff_ma@happyfan7.com \
    --action email "Send Alert to Dirk_-EmailAction-"  dirk_huang@happyfan7.com \
    --action email "Send Alert to Ken_-EmailAction-"   yokisei@gmail.com \
    --action email "Send Alert to Tom_-EmailAction-"   tom200e@hotmail.com \
    --action email "Send Alert to Corey_-EmailAction-" corey_chen@happyfan7.com \
    --action sms "Send Alert to Jeff_-SMSAction-"  886 982975589 \
    --action sms "Send Alert to Dirk_-SMSAction-"  886 955786368 \
    --action sms "Send Alert to Ken_-SMSAction-"   886 921926818 \
    --action sms "Send Alert to Corey_-SMSAction-" 886 968621720 \
    --output none; then
    log "   [OK] 建立完成: $AG_NAME (RG: $DST_RG)"
    (( SUCCESS++ )) || true
  else
    err "   [FAIL] 建立失敗: $AG_NAME (RG: $DST_RG)"
    (( FAILED++ )) || true
  fi
done

log ""
log "============================================"
log " 結果摘要"
log "   成功: $SUCCESS 個 RG"
log "   失敗: $FAILED 個 RG"
log "   Log : $LOG_FILE"
log "============================================"

[[ $FAILED -eq 0 ]]
