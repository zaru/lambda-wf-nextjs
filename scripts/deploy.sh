#!/usr/bin/env bash
# dist/app.zip を Lambda Web Function にデプロイする。
# 初回は Web Function とエンドポイントを作り、2 回目以降は revision を追加する。
# GitHub Actions（deploy.yml）から実行する前提だが、同じ環境変数を設定すれば手元からも実行できる。
#
# 必須の環境変数:
#   AWS_REGION, ARTIFACT_BUCKET, ASSETS_BUCKET, WEB_FUNCTION_NAME, WEB_FUNCTION_ROLE_ARN,
#   NETWORK_CONNECTOR_ARN, VALKEY_HOST, VALKEY_PORT, VALKEY_USERNAME, VALKEY_SECRET_ARN
# 任意の環境変数:
#   DISTRIBUTION_ARN  設定されていれば、CloudFront からの呼び出しを許可するリソースポリシーを付ける
#   APP_URL           設定されていれば、デプロイ後に /api/health でスモークテストする
#   GITHUB_SHA        revision の説明と S3 のキーに使う（なければ git から取る）
set -euo pipefail

cd "$(dirname "$0")/.."

: "${AWS_REGION:?}" "${ARTIFACT_BUCKET:?}" "${ASSETS_BUCKET:?}" "${WEB_FUNCTION_NAME:?}" "${WEB_FUNCTION_ROLE_ARN:?}"
: "${NETWORK_CONNECTOR_ARN:?}" "${VALKEY_HOST:?}" "${VALKEY_PORT:?}" "${VALKEY_USERNAME:?}"
: "${VALKEY_SECRET_ARN:?}"

ENDPOINT_NAME=prod
COMMIT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
ARTIFACT=dist/app.zip

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$1" >>"$GITHUB_STEP_SUMMARY"
  fi
}

[[ -f "$ARTIFACT" ]] || { echo "$ARTIFACT がありません。先に pnpm package を実行してください" >&2; exit 1; }

# 0. 静的ファイルを S3 に置く（CloudFront の /_next/static/* は S3 から配信する）。
#    revision を作る前に済ませる。新しい HTML が先に届いても、チャンクが 404 にならないようにするため。
#    --delete は付けない。旧ビルドのファイルを残し、デプロイ中に新旧の revision が混ざっても、
#    旧 HTML が参照するチャンクを配信できるようにする
STATIC_DIR=.next/static
[[ -d "$STATIC_DIR" ]] || { echo "$STATIC_DIR がありません。先に pnpm package を実行してください" >&2; exit 1; }
aws s3 sync "$STATIC_DIR" "s3://${ASSETS_BUCKET}/_next/static" \
  --cache-control "public,max-age=31536000,immutable" --only-show-errors
echo "synced static files to s3://${ASSETS_BUCKET}/_next/static"

# 1. デプロイパッケージをアップロードする（revision はオブジェクトのバージョンを参照する）
KEY="${WEB_FUNCTION_NAME}/${COMMIT_SHA}.zip"
VERSION_ID=$(aws s3api put-object \
  --bucket "$ARTIFACT_BUCKET" --key "$KEY" --body "$ARTIFACT" \
  --query VersionId --output text)
echo "uploaded s3://${ARTIFACT_BUCKET}/${KEY} (version ${VERSION_ID})"

# 2. Network Connector の最新のバージョン付き ARN を調べる
#    （Terraform からはバージョンなしの ARN しか取れないため、デプロイ時に解決する）
read -r CONNECTOR_STATE CONNECTOR_VERSION_ARN < <(aws lambda-core get-network-connector \
  --identifier "$NETWORK_CONNECTOR_ARN" \
  --query '[State, LatestVersionArn]' --output text)
if [[ "$CONNECTOR_STATE" != "ACTIVE" ]]; then
  echo "Network Connector が ACTIVE ではありません: $CONNECTOR_STATE" >&2
  exit 1
fi
echo "network connector: $CONNECTOR_VERSION_ARN"

# 3. revision の設定を組み立てる
REVISION_CONFIG=$(jq -n \
  --arg description "$COMMIT_SHA" \
  --arg bucket "$ARTIFACT_BUCKET" --arg key "$KEY" --arg versionId "$VERSION_ID" \
  --arg roleArn "$WEB_FUNCTION_ROLE_ARN" --arg connectorArn "$CONNECTOR_VERSION_ARN" \
  --arg valkeyHost "$VALKEY_HOST" --arg valkeyPort "$VALKEY_PORT" \
  --arg valkeyUsername "$VALKEY_USERNAME" --arg valkeySecretArn "$VALKEY_SECRET_ARN" \
  '{
    description: $description,
    buildConfig: {
      codeConfig: { s3Object: { bucket: $bucket, key: $key, versionId: $versionId } },
      runtimeConfig: { runtime: "nodejs24.x" }
    },
    serviceConfig: {
      executionRoleArn: $roleArn,
      timeoutSeconds: 30,
      maxConcurrencyPerEnvironment: 64,
      egressNetworkConnectorArn: $connectorArn,
      environmentVariables: {
        NODE_ENV: "production",
        VALKEY_HOST: $valkeyHost,
        VALKEY_PORT: $valkeyPort,
        VALKEY_TLS: "true",
        VALKEY_CLUSTER_MODE: "true",
        VALKEY_USERNAME: $valkeyUsername,
        VALKEY_SECRET_ARN: $valkeySecretArn
      },
      telemetryConfig: { loggingConfig: { applicationLogLevel: "INFO", systemLogLevel: "INFO" } }
    }
  }')

# 4. 初回は Web Function とエンドポイントを作り、2 回目以降は revision を追加する
if aws lambda-web get-web-function --function-name "$WEB_FUNCTION_NAME" >/dev/null 2>&1; then
  REVISION_ID=$(aws lambda-web create-web-function-revision \
    --cli-input-json "$(jq -n --arg name "$WEB_FUNCTION_NAME" --argjson revision "$REVISION_CONFIG" \
      '$revision + { functionName: $name }')" \
    --query revisionId --output text)
  echo "created revision $REVISION_ID"
else
  # エンドポイントは IamAuth にし、CloudFront の OAC からだけ呼べるようにする
  REVISION_ID=$(aws lambda-web create-web-function \
    --cli-input-json "$(jq -n --arg name "$WEB_FUNCTION_NAME" --arg endpoint "$ENDPOINT_NAME" \
      --argjson revision "$REVISION_CONFIG" \
      '{
        functionName: $name,
        revisionConfig: $revision,
        endpointConfig: {
          endpointName: $endpoint,
          endpointType: "HomeRegion",
          authType: "IamAuth",
          autoDeploymentMode: "LatestRevision"
        },
        tags: { Project: "wf-proto" }
      }')" \
    --query revision.revisionId --output text)
  echo "created web function $WEB_FUNCTION_NAME with revision $REVISION_ID"
  aws lambda-web wait web-function-active --function-name "$WEB_FUNCTION_NAME"
fi

# 5. revision が Active になるまで待つ
aws lambda-web wait web-function-revision-active \
  --function-name "$WEB_FUNCTION_NAME" --revision-id "$REVISION_ID"
echo "revision $REVISION_ID is active"

aws lambda-web wait web-function-endpoint-active \
  --function-name "$WEB_FUNCTION_NAME" --endpoint-name "$ENDPOINT_NAME"
ENDPOINT_DOMAIN=$(aws lambda-web get-web-function-endpoint \
  --function-name "$WEB_FUNCTION_NAME" --endpoint-name "$ENDPOINT_NAME" \
  --query domainName --output text)
ENDPOINT_ARN=$(aws lambda-web get-web-function-endpoint \
  --function-name "$WEB_FUNCTION_NAME" --endpoint-name "$ENDPOINT_NAME" \
  --query endpointArn --output text)
echo "endpoint domain: ${ENDPOINT_DOMAIN}（Terraform の web_function_endpoint_domain に設定する値）"

# 6. CloudFront の OAC からの呼び出しを許可する（毎回上書きするので冪等）
if [[ -n "${DISTRIBUTION_ARN:-}" ]]; then
  FUNCTION_ARN=$(aws lambda-web get-web-function --function-name "$WEB_FUNCTION_NAME" \
    --query functionArn --output text)
  POLICY=$(jq -n --arg endpointArn "$ENDPOINT_ARN" --arg distributionArn "$DISTRIBUTION_ARN" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Sid: "AllowCloudFrontOAC",
        Effect: "Allow",
        Principal: { Service: "cloudfront.amazonaws.com" },
        Action: "lambda:InvokeWebFunctionEndpoint",
        Resource: $endpointArn,
        Condition: { StringEquals: { "aws:SourceArn": $distributionArn } }
      }]
    }')
  aws lambda-web put-resource-policy --resource-arn "$FUNCTION_ARN" --policy "$POLICY" >/dev/null
  echo "resource policy allows $DISTRIBUTION_ARN"
else
  echo "DISTRIBUTION_ARN が未設定のため、リソースポリシーの設定を省略しました"
fi

# 7. スモークテスト（CloudFront 経由）
if [[ -n "${APP_URL:-}" ]]; then
  # LatestRevision モードでも、エンドポイントの切り替えには少し時間がかかることがある
  for attempt in 1 2 3 4 5 6; do
    if curl -fsS --max-time 30 "${APP_URL}/api/health"; then
      echo
      echo "smoke test passed"
      break
    fi
    if [[ "$attempt" == 6 ]]; then
      echo "smoke test failed" >&2
      exit 1
    fi
    sleep 10
  done
else
  echo "APP_URL が未設定のため、スモークテストを省略しました"
fi

summary "### Deployed ${WEB_FUNCTION_NAME}"
summary ""
summary "| 項目 | 値 |"
summary "| --- | --- |"
summary "| revision | \`${REVISION_ID}\` |"
summary "| commit | \`${COMMIT_SHA}\` |"
summary "| endpoint domain | \`${ENDPOINT_DOMAIN}\` |"
summary "| app url | ${APP_URL:-（CloudFront 未作成）} |"
