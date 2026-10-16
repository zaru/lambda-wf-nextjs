#!/usr/bin/env bash
# CloudWatch Logs Insights のクエリを実行し、結果を 1 行 1 件で表示する。
#
# 使い方:
#   scripts/insights.sh <開始時刻> <終了時刻> <プリセット名 | クエリ文字列>
#
#   時刻は UTC の ISO 8601 形式（例: 2026-10-16T05:45:00Z）
#
# プリセット:
#   environments  実行環境ごとのリクエスト数と遅延（スケールアウトしたか、遅い実行環境があるか）
#   coldstarts    実行環境の起動（ready）、ウォームアップ、各実行環境の最初のリクエスト。
#                 最初のリクエストの sinceReadyMs が数百 ms なら、そのリクエストは実行環境の起動を待っていた。
#                 数秒以上なら、先に起動していた実行環境に後からリクエストが来た
#   slow          遅かったリクエスト（durationMs の降順で上位 50 件）
#   errors        ステータスが 500 以上のリクエストと、アプリのエラーログ
#
# 例:
#   scripts/insights.sh 2026-10-16T05:45:00Z 2026-10-16T06:15:00Z environments
#   scripts/insights.sh 2026-10-16T05:45:00Z 2026-10-16T06:15:00Z 'fields @message | limit 20'
#
# 環境変数:
#   LOG_GROUP   対象のロググループ（既定: /aws/lambda/web/wf-proto-todo）。
#               結果が空のときは、リージョン内のログが書かれる <名前>.local も試す
#   AWS_REGION  リージョン（既定: ap-northeast-1）
set -euo pipefail

LOG_GROUP="${LOG_GROUP:-/aws/lambda/web/wf-proto-todo}"
REGION="${AWS_REGION:-ap-northeast-1}"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 1
}

[[ $# -eq 3 ]] || usage

start="$1"
end="$2"
query="$3"

case "$query" in
  environments)
    query='fields @timestamp
| filter type = "access"
| stats count() as requests, pct(durationMs, 50) as p50, pct(durationMs, 95) as p95, max(durationMs) as max by environmentId'
    ;;
  coldstarts)
    query='fields @timestamp, environmentId, type, message, path, durationMs, sinceReadyMs, uptimeMs, timings.valkeyConnect, timings.secrets
| filter coldStart = 1 or type = "ready" or @message like /warmup/
| sort @timestamp asc'
    ;;
  slow)
    query='fields @timestamp, environmentId, method, path, status, durationMs, coldStart, timings.valkey, timings.valkeyConnect, timings.external
| filter type = "access"
| sort durationMs desc
| limit 50'
    ;;
  errors)
    query='fields @timestamp, environmentId, level, message, errorName, errorMessage, method, path, status, @message
| filter status >= 500 or level = "error" or level = "warn" or level = "ERROR" or level = "WARN"
| sort @timestamp asc'
    ;;
esac

# ISO 8601（UTC）を UNIX 時間に変換する（macOS の BSD date と GNU date の両方に対応）
to_epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}

query_id=$(aws logs start-query --region "$REGION" \
  --log-group-names "$LOG_GROUP" \
  --start-time "$(to_epoch "$start")" \
  --end-time "$(to_epoch "$end")" \
  --query-string "$query" \
  --query queryId --output text)

while :; do
  result=$(aws logs get-query-results --region "$REGION" --query-id "$query_id")
  status=$(jq -r .status <<<"$result")
  case "$status" in
    Complete) break ;;
    Failed | Cancelled | Timeout)
      echo "クエリが終了しませんでした: $status" >&2
      exit 1
      ;;
  esac
  sleep 2
done

jq -r '.results[] | map(select(.field != "@ptr") | "\(.field)=\(.value)") | join("  ")' <<<"$result"
jq -r '"# \(.results | length) 件（スキャン \(.statistics.recordsScanned | floor) レコード、\(.statistics.bytesScanned / 1048576 * 100 | floor / 100) MB）"' <<<"$result" >&2
