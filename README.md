# lambda-wf-nextjs

Lambda Web Functions を本番に近い構成で検証するための TODO アプリです。

- アプリ: Next.js（App Router）、Server Actions
- 実行基盤: Lambda Web Functions（`nodejs24.x` / arm64）
- データストア: ElastiCache Serverless for Valkey（VPC 内、Network Connector 経由）
- 入口: CloudFront（OAC）＋ `wf.dev.id.basicinc.jp`
- 外部通信: NAT Gateway 経由（祝日 API、Secrets Manager）

設計は [docs/design.md](docs/design.md)、ネットワーク構成の検討は [docs/network-options.md](docs/network-options.md) を参照してください。

検証を再開するときは、まず [docs/notes.md](docs/notes.md)（現在の状態、未決定事項、作業中に踏んだ落とし穴）を読んでください。 デプロイ中に新旧の revision が混ざるかの調査は [docs/deploy-mixing.md](docs/deploy-mixing.md) を参照してください。

検証で分かったことの総括は [docs/lessons-learned.md](docs/lessons-learned.md) にまとめています。

## 必要なもの

| ツール | バージョン | 用途 |
| --- | --- | --- |
| Node.js | 24 系（Web Functions のランタイムに合わせる） | アプリ |
| pnpm | 11 系 | パッケージ管理 |
| Terraform | 1.8 以上 | インフラ |
| AWS CLI v2 | `lambda-web` / `lambda-core` コマンドに対応した最新版 | Web Function の操作（`aws lambda-web help` で確認） |
| GitHub CLI | 任意 | Repository variables の登録 |
| k6 | 任意 | 負荷試験 |

## ローカル開発

```bash
pnpm install
cp .env.example .env.local
docker compose up -d   # Valkey（TLS なし・認証なし）
pnpm dev
```

Web Functions と同じ起動方法（`lambda/index.js` 経由）で確かめる場合:

```bash
pnpm package
AWS_LAMBDA_HTTP_ENDPOINT=127.0.0.1:3000 VALKEY_HOST=127.0.0.1 pnpm start:standalone
```

| コマンド | 内容 |
| --- | --- |
| `pnpm lint` / `pnpm format` | Biome によるチェック / 自動修正 |
| `pnpm typecheck` | 型チェック |
| `pnpm package` | ビルドして `dist/app.zip` を作る |

## 構築

Terraform の state はローカル（`infra/terraform/terraform.tfstate`）に置きます。**state をなくすと destroy できず、NAT Gateway などの費用がかかり続けます。** 撤去するまで手元で保管してください。state には Valkey のパスワードが入るので、コミットしないでください（`.gitignore` 済み）。

### 1. インフラを作る（1 回目の apply）

```bash
cd infra/terraform
terraform init
terraform apply
```

Network Connector の作成に 10 分ほどかかります。この時点では CloudFront は作られません。

### 2. GitHub の Repository variables を登録する

```bash
terraform output -json github_variables \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' > /tmp/wf-proto-vars.env
gh variable set -f /tmp/wf-proto-vars.env -R zaru/lambda-wf-nextjs
```

### 3. 初回デプロイ

main に push するか、Actions の **deploy** ワークフローを手動で実行します。Web Function とエンドポイント（`IamAuth`）が作られます。ログと Job Summary に出る **endpoint domain** を控えてください。

### 4. CloudFront を作る（2 回目の apply）

```bash
cp terraform.tfvars.example terraform.tfvars
# web_function_endpoint_domain に、手順 3 の endpoint domain を設定する
terraform apply
```

### 5. 変数を登録し直して、再デプロイする

手順 2 をもう一度実行します（`DISTRIBUTION_ARN` と `APP_URL` が増えます）。その後、deploy ワークフローを実行します。CloudFront からの呼び出しを許可するリソースポリシーが設定され、スモークテストが実行されます。

`https://wf.dev.id.basicinc.jp` にアクセスして動作を確認してください。

## デプロイ

main に push すると、deploy ワークフローが新しい revision を作ります。エンドポイントは `LatestRevision` モードなので、revision が Active になると自動で切り替わります。

### カナリアリリース

Actions の **canary** ワークフロー（または手元の `scripts/canary.sh`）を使います。

1. `pin`: 現在の revision に固定する（以後のデプロイでは切り替わらない）
2. main に push する → 新しい revision が作られる（トラフィックはまだ流れない）
3. `shift`: 新しい revision の ID と割合（例: 10）を指定する
4. 問題がなければ `promote`（100% にして、自動デプロイに戻す）。問題があれば `rollback`

`status` で現在の割り当てを確認できます。

## 計測

計測は CloudFront 経由（既定の `BASE_URL` は `https://wf.dev.id.basicinc.jp`）で行います。結果は `loadtest/results/` に保存されます。

```bash
# 事前に、アカウントの Web Functions の上限（秒間リクエスト数、Arm vCPU 数）を確認する
aws lambda-web get-web-account-settings

# レイテンシ（約 2.6 rps × 5 分）
k6 run -e SCENARIO=latency loadtest/scenarios.js

# 負荷試験（4 シナリオの合計で約 1.8 万リクエスト）
k6 run -e SCENARIO=steady loadtest/scenarios.js   # 10 rps × 5 分
k6 run -e SCENARIO=ramp   loadtest/scenarios.js   # 0 → 50 rps（5 分）
k6 run -e SCENARIO=spike  loadtest/scenarios.js   # 5 秒で 50 rps に上げて 2 分

# コールドスタート（既定は 5/15/30/60 分の間隔で、合計約 2 時間）
loadtest/coldstart.sh
```

- 書き込みは、あらかじめ用意した TODO（既定 30 件）の完了状態を切り替えます
- `/api/diag/external` は第三者の祝日 API を呼ぶため、`latency` シナリオで 20 秒に 1 回だけ呼びます。負荷試験には含めないでください
- サーバー側の内訳は、レスポンスの `Server-Timing` ヘッダと、CloudWatch Logs（`/aws/lambda/web/wf-proto-todo`）のアクセスログ（`type: "access"`、`coldStart`）で確認できます

### ログの集計（CloudWatch Logs Insights）

`scripts/insights.sh` で、計測した時間帯（UTC）のログを集計できます。

```bash
scripts/insights.sh 2026-10-16T05:45:00Z 2026-10-16T06:15:00Z environments  # 実行環境ごとのリクエスト数と遅延
scripts/insights.sh 2026-10-16T05:45:00Z 2026-10-16T06:15:00Z coldstarts    # コールドスタートと初期化時間
scripts/insights.sh 2026-10-16T05:45:00Z 2026-10-16T06:15:00Z slow          # 遅かったリクエストの上位 50 件
scripts/insights.sh 2026-10-16T05:45:00Z 2026-10-16T06:15:00Z errors        # 5xx とエラーログ
scripts/insights.sh <開始> <終了> 'fields @message | limit 20'                # 任意のクエリ
```

結果が空のときは、`LOG_GROUP=/aws/lambda/web/wf-proto-todo.local` を付けて試してください（Web Functions は、リージョン内のログを `.local` に書いてから集約します）。

## 撤去

```bash
scripts/destroy-web-function.sh   # Web Function を削除する（Connector を参照する revision を先に消すため）
cd infra/terraform
terraform destroy
```
