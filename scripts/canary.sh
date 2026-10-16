#!/usr/bin/env bash
# エンドポイントのトラフィックを revision 間で切り替える（カナリアリリース）。
#
# 使い方:
#   canary.sh pin                       現在の revision に固定する（以後のデプロイでは切り替わらない）
#   canary.sh shift <revision-id> <%>   新しい revision に指定した割合を流す
#   canary.sh promote <revision-id>     新しい revision に 100% 流し、自動デプロイに戻す
#   canary.sh rollback                  直前まで 100% を受けていた revision に戻し、固定する
#   canary.sh status                    現在の割り当てを表示する
set -euo pipefail

: "${WEB_FUNCTION_NAME:?}"
ENDPOINT_NAME=prod

endpoint() {
  aws lambda-web get-web-function-endpoint \
    --function-name "$WEB_FUNCTION_NAME" --endpoint-name "$ENDPOINT_NAME" "$@"
}

update() {
  aws lambda-web update-web-function-endpoint \
    --function-name "$WEB_FUNCTION_NAME" --endpoint-name "$ENDPOINT_NAME" "$@" >/dev/null
  aws lambda-web wait web-function-endpoint-updated \
    --function-name "$WEB_FUNCTION_NAME" --endpoint-name "$ENDPOINT_NAME"
}

# 重みがいちばん大きい revision（canary 中は現行版）
stable_revision() {
  endpoint --query 'max_by(revisionWeights, &weight).revisionId' --output text
}

command="${1:-status}"
case "$command" in
  status)
    endpoint --query '{autoDeploymentMode: autoDeploymentMode, revisionWeights: revisionWeights}'
    ;;
  pin)
    current=$(stable_revision)
    update --auto-deployment-mode Disabled \
      --revision-weights "$(jq -cn --arg id "$current" '[{revisionId: $id, weight: 100}]')"
    echo "pinned to $current"
    ;;
  shift)
    target="${2:?revision-id を指定してください}"
    percent="${3:?割合（1-99）を指定してください}"
    current=$(stable_revision)
    if [[ "$current" == "$target" ]]; then
      echo "対象の revision はすでに主系です: $target" >&2
      exit 1
    fi
    update --auto-deployment-mode Disabled \
      --revision-weights "$(jq -cn --arg cur "$current" --arg new "$target" --argjson p "$percent" \
        '[{revisionId: $cur, weight: (100 - $p)}, {revisionId: $new, weight: $p}]')"
    echo "$target に ${percent}% を割り当てました（残りは ${current}）"
    ;;
  promote)
    target="${2:?revision-id を指定してください}"
    update --auto-deployment-mode Disabled \
      --revision-weights "$(jq -cn --arg id "$target" '[{revisionId: $id, weight: 100}]')"
    update --auto-deployment-mode LatestRevision
    echo "promoted $target and re-enabled automatic deployment"
    ;;
  rollback)
    current=$(stable_revision)
    update --auto-deployment-mode Disabled \
      --revision-weights "$(jq -cn --arg id "$current" '[{revisionId: $id, weight: 100}]')"
    echo "rolled back to ${current}（自動デプロイは無効のまま。戻すときは promote を使う）"
    ;;
  *)
    echo "unknown command: $command" >&2
    exit 1
    ;;
esac
