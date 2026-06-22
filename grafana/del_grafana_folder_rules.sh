#!/usr/bin/env bash
# =============================================================================
# 06_delete_grafana_folder_rules.sh
# 刪除指定 Grafana folder 底下的所有 alert rules
# 支援 dry-run 模式（預設），加 --apply 才真的刪
# =============================================================================
set -u

export GRAFANA_URL="https://grafana-aca.credithome.com.tw"
export GRAFANA_ADMIN_USER="admin"
export GRAFANA_ADMIN_PASSWORD="password123"
export AZURE_DATASOURCE_UID="bf7jxviy4zksge"
# ── 環境變數（與其他腳本一致）────────────────────────────────────────────────
GRAFANA_URL="${GRAFANA_URL:-https://grafana-aca.credithome.com.tw}"
GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-}"
FOLDER_UID="${GRAFANA_FOLDER_UID:-}"   # 若已知可直接填；否則腳本會用 FOLDER_NAME 查

# Folder 名稱（用來查 UID，若 FOLDER_UID 已設可略過）
FOLDER_NAME="${GRAFANA_FOLDER_NAME:-Backup-Alerts}"
#FOLDER_TITLE="Backup-Alerts"

# ── 旗標────────────────────────────────────────────────────────────────────────
DRY_RUN=true
for arg in "$@"; do
  [[ "$arg" == "--apply" ]] && DRY_RUN=false
done

if $DRY_RUN; then
  echo "============================================"
  echo " [DRY-RUN] 僅列出將被刪除的 rules，不實際刪除"
  echo " 確認無誤後加 --apply 參數重新執行"
  echo "============================================"
else
  echo "============================================"
  echo " [APPLY] 即將永久刪除 rules，無法還原！"
  echo "============================================"
  read -rp " 確認刪除？輸入 yes 繼續：" CONFIRM
  [[ "$CONFIRM" != "yes" ]] && echo "已取消。" && exit 0
fi

# ── 基本設定────────────────────────────────────────────────────────────────────
AUTH="-u ${GRAFANA_USER}:${GRAFANA_PASS}"
HEADERS=(-H "Content-Type: application/json" -H "Accept: application/json")
BASE="${GRAFANA_URL}/api/v1/provisioning"

# ── Step 1: 查 Folder UID（若未設定）──────────────────────────────────────────
if [[ -z "$FOLDER_UID" ]]; then
  echo
  echo ">> 查詢 folder UID (name: ${FOLDER_NAME})..."
  FOLDERS=$(curl -sf $AUTH "${HEADERS[@]}" "${GRAFANA_URL}/api/folders?limit=100")
  FOLDER_UID=$(echo "$FOLDERS" | jq -r \
    --arg name "$FOLDER_NAME" \
    '.[] | select(.title == $name) | .uid' | head -1)

  if [[ -z "$FOLDER_UID" ]]; then
    echo "ERROR: 找不到 folder「${FOLDER_NAME}」，請確認 GRAFANA_FOLDER_NAME 或手動設定 GRAFANA_FOLDER_UID"
    echo "現有 folders："
    echo "$FOLDERS" | jq -r '.[] | "  \(.uid)  \(.title)"'
    exit 1
  fi
  echo "   Folder UID: ${FOLDER_UID}"
fi

# ── Step 2: 列出該 folder 所有 alert rules──────────────────────────────────────
echo
echo ">> 取得 folder ${FOLDER_UID} 的所有 alert rules..."
ALL_RULES=$(curl -sf $AUTH "${HEADERS[@]}" "${BASE}/alert-rules" \
  | jq --arg fuid "$FOLDER_UID" '[.[] | select(.folderUID == $fuid)]')

TOTAL=$(echo "$ALL_RULES" | jq 'length')

if [[ "$TOTAL" -eq 0 ]]; then
  echo "   Folder 內無任何 alert rules，不需刪除。"
  exit 0
fi

echo "   找到 ${TOTAL} 條 rules："
echo "$ALL_RULES" | jq -r '.[] | "   [\(.uid)]  \(.title)"'

# ── Step 3: 刪除────────────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo
  echo ">> [DRY-RUN] 以上 ${TOTAL} 條 rules 將被刪除。"
  echo "   確認無誤後執行：$0 --apply"
  exit 0
fi

echo
echo ">> 開始刪除..."
SUCCESS=0
FAILED=0

while IFS= read -r UID_TITLE; do
  RULE_UID=$(echo "$UID_TITLE" | cut -f1)
  RULE_TITLE=$(echo "$UID_TITLE" | cut -f2-)

  HTTP_CODE=$(curl -s -o /tmp/gf_del_resp.json -w "%{http_code}" \
    $AUTH "${HEADERS[@]}" \
    -X DELETE "${BASE}/alert-rules/${RULE_UID}")

  if [[ "$HTTP_CODE" == "204" || "$HTTP_CODE" == "200" ]]; then
    echo "   [OK]   ${RULE_TITLE}"
    SUCCESS=$((SUCCESS+1))
  else
    BODY=$(cat /tmp/gf_del_resp.json 2>/dev/null || echo "no body")
    echo "   [FAIL] ${RULE_TITLE} (HTTP ${HTTP_CODE}) — ${BODY}"
    FAILED=$((FAILED+1))
  fi
done < <(echo "$ALL_RULES" | jq -r '.[] | "\(.uid)\t\(.title)"')

# ── 摘要────────────────────────────────────────────────────────────────────────
echo
echo "============================================"
echo " [刪除完成]"
echo "   成功: ${SUCCESS} 條"
echo "   失敗: ${FAILED} 條"
echo "============================================"

[[ "$FAILED" -gt 0 ]] && exit 1 || exit 0
