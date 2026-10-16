#!/usr/bin/env bash
# Web Function（revision とエンドポイントを含む）を削除する。
# Network Connector を参照している revision が残っていると Connector を安全に消せないため、
# terraform destroy の前に実行する。手元の管理者権限で実行する想定。
set -euo pipefail

WEB_FUNCTION_NAME="${WEB_FUNCTION_NAME:-wf-proto-todo}"
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"

if ! aws lambda-web get-web-function --function-name "$WEB_FUNCTION_NAME" >/dev/null 2>&1; then
  echo "$WEB_FUNCTION_NAME は存在しません"
  exit 0
fi

read -r -p "$WEB_FUNCTION_NAME を削除します（region: ${AWS_REGION}）。よろしいですか？ [y/N] " answer
[[ "$answer" == "y" ]] || { echo "中止しました"; exit 1; }

aws lambda-web delete-web-function --function-name "$WEB_FUNCTION_NAME"
aws lambda-web wait web-function-deleted --function-name "$WEB_FUNCTION_NAME"
echo "deleted $WEB_FUNCTION_NAME"
