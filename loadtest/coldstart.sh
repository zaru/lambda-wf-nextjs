#!/usr/bin/env bash
# コールドスタートの計測（設計書 9.2 節）。
# アクセスしない時間（分）を変えながら 1 リクエストずつ送り、応答時間と Server-Timing を記録する。
# 長い間隔は実行時間が長くなる（既定の 5,15,30,60 分で合計約 2 時間）。
#
#   loadtest/coldstart.sh                       既定の間隔で計測する
#   IDLE_MINUTES="1 5" loadtest/coldstart.sh    間隔を指定する
#   REPEAT=3 loadtest/coldstart.sh              各間隔を 3 回ずつ計測する
#
# 結果: loadtest/results/coldstart-<日時>.csv
# サーバー側の内訳は CloudWatch Logs のアクセスログ（coldStart: true）と突き合わせる。
set -euo pipefail

cd "$(dirname "$0")/.."

BASE_URL="${BASE_URL:-https://wf.dev.id.basicinc.jp}"
IDLE_MINUTES="${IDLE_MINUTES:-5 15 30 60}"
REPEAT="${REPEAT:-1}"
PATHS=("/api/health" "/")

mkdir -p loadtest/results
OUT="loadtest/results/coldstart-$(date +%Y%m%dT%H%M%S).csv"
echo "timestamp,idle_minutes,path,status,ttfb_ms,total_ms,server_timing" >"$OUT"

measure() {
  local idle="$1" path="$2" headers result
  headers=$(mktemp)
  result=$(curl -s -o /dev/null -D "$headers" \
    -w '%{http_code},%{time_starttransfer},%{time_total}' "${BASE_URL}${path}")
  local status ttfb total timing
  IFS=, read -r status ttfb total <<<"$result"
  timing=$(grep -i '^server-timing:' "$headers" | cut -d' ' -f2- | tr -d '\r' || true)
  rm -f "$headers"
  printf '%s,%s,%s,%s,%.1f,%.1f,"%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$idle" "$path" "$status" \
    "$(echo "$ttfb * 1000" | bc)" "$(echo "$total * 1000" | bc)" "$timing" | tee -a "$OUT"
}

for idle in $IDLE_MINUTES; do
  for ((i = 1; i <= REPEAT; i++)); do
    echo "# ${idle} 分待機します（$(date '+%H:%M:%S') 開始）"
    sleep $((idle * 60))
    # 1 回目がコールドスタート、続けて送る 2 回目以降はウォームの比較用
    for path in "${PATHS[@]}"; do
      measure "$idle" "$path"
    done
    for path in "${PATHS[@]}"; do
      measure "${idle}-warm" "$path"
    done
  done
done

echo "saved: $OUT"
