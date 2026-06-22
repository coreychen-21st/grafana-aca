#!/usr/bin/env bash
# ============================================================
# 01_list_app_service_plans.sh
# 列出所有 Subscription 中的 App Service Plan
# 並輸出 prod 環境清單到 prod_asp.json
# ============================================================

#set -euo pipefail
set -u

OUTPUT_FILE="prod_asp.json"

echo "==> 取得所有 Subscriptions..."
SUBSCRIPTIONS=$(az account list --query "[].{id:id, name:name}" -o json)
echo "找到 Subscriptions："
echo "$SUBSCRIPTIONS" | jq -r '.[] | "  - \(.name) (\(.id))"'

ALL_PLANS=()

echo ""
echo "==> 掃描所有 Subscription 下的 App Service Plan..."

while IFS= read -r SUB_ID; do
  SUB_NAME=$(echo "$SUBSCRIPTIONS" | jq -r --arg id "$SUB_ID" '.[] | select(.id==$id) | .name')
  echo "  Subscription: $SUB_NAME ($SUB_ID)"

  PLANS=$(az appservice plan list \
    --subscription "$SUB_ID" \
    --query "[].{
      name:name,
      resourceGroup:resourceGroup,
      location:location,
      sku:sku.name,
      tier:sku.tier,
      capacity:sku.capacity,
      subscriptionId:'$SUB_ID',
      subscriptionName:'$SUB_NAME',
      tags:tags
    }" \
    -o json 2>/dev/null || echo "[]")

  COUNT=$(echo "$PLANS" | jq 'length')
  echo "    找到 $COUNT 個 App Service Plan"

  # 合併結果
  if [ "$COUNT" -gt 0 ]; then
    ALL_PLANS+=("$PLANS")
  fi

done < <(echo "$SUBSCRIPTIONS" | jq -r '.[].id')

# 合併所有結果
echo ""
echo "==> 合併結果，篩選 prod 環境..."

# 合併所有 JSON 陣列
MERGED=$(printf '%s\n' "${ALL_PLANS[@]}" | jq -s 'add // []')

# 篩選 prod 環境：名稱或 tag 含 prod / production / prd
PROD_PLANS=$(echo "$MERGED" | jq '[
  .[] | select(
    (.name | ascii_downcase | test("prod|prd|production|ai|aiservice|taogefu|taoge|crossplat")) or
    (.name | test("正式機|正式")) or
    (.resourceGroup | ascii_downcase | test("prod|prd|production|ai|aiservice|taogefu|taoge|crossplat")) or
    (.tags != null and (
      (.tags | to_entries[] | .value | ascii_downcase | test("prod|prd|production|ai|aiservice|taogefu|taoge|crossplat")) or
      (.tags.environment // "" | ascii_downcase | test("prod|prd|production|ai|aiservice|taogefu|taoge|crossplat")) or
      (.tags.env // "" | ascii_downcase | test("prod|prd|production|ai|aiservice|taogefu|taoge|crossplat"))
    ))
  ) | select(.name | test("測試|test|Pi|PiEncr") | not)
]')

PROD_COUNT=$(echo "$PROD_PLANS" | jq 'length')

echo ""
echo "============================================"
echo " Prod App Service Plans 清單 (共 $PROD_COUNT 個)"
echo "============================================"
echo "$PROD_PLANS" | jq -r '.[] | "  [\(.subscriptionName)] \(.resourceGroup)/\(.name) | SKU: \(.sku) | Location: \(.location)"'

# 輸出到檔案
echo "$PROD_PLANS" | jq '.' > "$OUTPUT_FILE"
echo ""
echo "==> 已儲存到 $OUTPUT_FILE"
