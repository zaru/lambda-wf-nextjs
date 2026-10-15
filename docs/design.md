# TODO デモアプリ 設計書

- 作成日: 2026-10-15
- ステータス: ドラフト（レビュー待ち）

## 1. 概要

Next.js（App Router）で作る TODO 管理のデモアプリ。Lambda Web Functions（2026-10-12 GA）の上で Next.js を動かし、データは ElastiCache Serverless for Valkey に保存する構成を検証する。

### 1.1 目的

- Lambda Web Functions で Next.js（SSR と Server Actions）が動くことを確かめる
- Web Function から VPC 内の ElastiCache（Valkey）に、Lambda Network Connector 経由で接続する構成を確かめる
- Terraform（インフラ）と GitHub Actions（アプリのデプロイ）の役割分担を確立する

### 1.2 スコープ外

- ユーザー認証と、ユーザーごとの TODO 分離（全員で 1 つのリストを共有する）
- カスタムドメイン、CloudFront、WAF
- マルチリージョン構成（Network Connector は `HomeRegion` エンドポイントでしか使えないため）
- 本番相当の可用性設計と監視

## 2. 全体アーキテクチャ

```
                        ┌──────────────────────── AWS (ap-northeast-1) ────────────────────────┐
                        │                                                                        │
 Browser ──HTTPS──▶  Lambda Web Function endpoint (HomeRegion / ApplicationManaged)             │
                        │         │                                                              │
                        │         ▼                                                              │
                        │   Web Function revision (nodejs24.x / arm64)                           │
                        │   Next.js standalone server (SSR + Server Actions)                     │
                        │         │ egress                                                       │
                        │         ▼                                                              │
                        │   Lambda Network Connector ──ENI──┐                                    │
                        │                                    │                                   │
                        │   ┌─────────── VPC 10.0.0.0/16 ────┼──────────────────────────┐        │
                        │   │  private subnet (AZ-a)  private subnet (AZ-c)            │        │
                        │   │        [ENI]  ──TLS:6379──▶  ElastiCache Serverless       │        │
                        │   │                               for Valkey                  │        │
                        │   └───────────────────────────────────────────────────────────┘        │
                        │                                                                        │
                        │   S3 (deploy artifacts, versioned)    CloudWatch Logs                  │
                        └────────────────────────────────────────────────────────────────────────┘

 GitHub Actions ──OIDC──▶ IAM Role ──▶ S3 へ zip をアップロード ──▶ lambda-web API で revision を作成
```

### 2.1 主要な技術選定

| 項目 | 採用 | 理由 / 主な代替案 |
| --- | --- | --- |
| フレームワーク | Next.js（App Router、最新安定版）、TypeScript | 指定どおり |
| 実行基盤 | Lambda Web Functions（`nodejs24.x` / arm64） | 指定どおり。アダプタなしで `next start` 相当の standalone サーバーをそのまま動かせる |
| データストア | ElastiCache **Serverless** for Valkey | デモ用途で容量設計が要らず、Terraform 1 リソースで作れる。代替案のノードベース（`cache.t4g.micro`）は最低料金が安い場合があるが、サブネットグループやパラメータグループなどの管理が増える |
| Valkey クライアント | `iovalkey`（ioredis の Valkey 向けフォーク、純 JS） | ネイティブバイナリが要らず、arm64 向けのビルドで困らない。代替案の `@valkey/valkey-glide` は公式だがネイティブモジュールを含み、standalone 出力と zip パッケージの扱いが難しくなる |
| VPC 接続 | Lambda Network Connector（egress） | Web Function から VPC 内リソースに届く唯一の方法 |
| パッケージマネージャ | pnpm | 新規 JS プロジェクトの方針 |
| Linter / Formatter | Biome | 同上 |
| IaC | Terraform（`hashicorp/aws` >= 6.61） | 指定どおり。`aws_lambdacore_network_connector` が 6.61.0 で追加された |
| CI/CD | GitHub Actions（OIDC で AssumeRole） | 指定どおり。長期のアクセスキーを持たない |
| リージョン | ap-northeast-1（東京） | Web Functions の提供リージョンに含まれる |

## 3. アプリケーション設計

### 3.1 機能一覧

| # | 機能 | 説明 |
| --- | --- | --- |
| F1 | 一覧表示 | TODO を作成日時の新しい順に表示する |
| F2 | 追加 | タイトルを入力して追加する（1〜200 文字。前後の空白は除去する） |
| F3 | 完了切り替え | チェックボックスで完了と未完了を切り替える |
| F4 | タイトル編集 | インライン編集。空文字にした場合は保存しない |
| F5 | 削除 | 1 件ずつ削除する |
| F6 | フィルタ | すべて / 未完了 / 完了済み。URL の `?filter=` で状態を持つ |
| F7 | 完了済みを一括削除 | 完了済みの TODO をまとめて削除する |
| F8 | ヘルスチェック | `GET /api/health` が Valkey へ `PING` を送り、結果を返す |

### 3.2 画面

1 画面（`/`）だけで構成する。

```
┌───────────────────────────────────────────┐
│  TODO Demo                                 │
│  ┌─────────────────────────────┐ [追加]    │
│  │ 新しいタスクを入力…         │           │
│  └─────────────────────────────┘           │
│  [すべて] [未完了] [完了済み]   残り 3 件   │
│  ─────────────────────────────────────────  │
│  ☐ 牛乳を買う                    [編集][×] │
│  ☑ 設計書を書く                  [編集][×] │
│  ─────────────────────────────────────────  │
│                       [完了済みを一括削除] │
└───────────────────────────────────────────┘
```

### 3.3 レンダリングとデータ更新の方針

- `app/page.tsx` は Server Component とし、リクエストごとに Valkey から読む（`export const dynamic = "force-dynamic"`）
  - Web Function は複数の実行環境にスケールし、Next.js のキャッシュは環境ごとに独立する。環境間で表示がずれないよう、Next.js のデータキャッシュとフルルートキャッシュは使わない
- 書き込みはすべて Server Actions（`app/actions.ts`）で行う。処理後に `revalidatePath("/")` を呼ぶ
- クライアント側では `useOptimistic` で楽観的更新を行い、体感速度を上げる
- 入力値は Server Action 側で zod を使って検証する

### 3.4 ディレクトリ構成（アプリ）

```
.
├── app/
│   ├── layout.tsx
│   ├── page.tsx               # 一覧（Server Component）
│   ├── actions.ts             # Server Actions（追加/更新/削除/一括削除）
│   ├── api/health/route.ts    # ヘルスチェック
│   └── _components/           # TodoForm, TodoItem, FilterTabs など（Client Component）
├── lib/
│   ├── valkey.ts              # クライアント生成（シングルトン）
│   └── todo-repository.ts     # データアクセス
├── lambda/
│   └── index.js               # Web Functions 用エントリ（standalone server.js を起動）
├── scripts/
│   └── package.sh             # standalone 出力を zip にまとめる
├── infra/terraform/           # 6 章
├── .github/workflows/         # 7 章
├── docker-compose.yml         # ローカル用 Valkey
├── biome.json
├── next.config.ts             # output: "standalone"
└── package.json
```

### 3.5 データモデル（Valkey）

全員で 1 つのリストを共有する前提なので、1 つの Hash にすべての TODO を入れる。

| キー | 型 | 内容 |
| --- | --- | --- |
| `{todo}:items` | Hash | field = TODO の ID（UUID v7）、value = TODO を表す JSON 文字列 |

TODO の JSON:

```json
{
  "id": "0192f1c2-...",
  "title": "牛乳を買う",
  "completed": false,
  "createdAt": "2026-10-15T09:00:00.000Z",
  "updatedAt": "2026-10-15T09:00:00.000Z"
}
```

- 一覧は `HGETALL` で全件を取得し、アプリ側で `createdAt` の降順に並べる。デモの件数（数百件程度）なら問題ない
- UUID v7 は時刻順に並ぶので、ID で並べても作成順になる
- キーをハッシュタグ `{todo}` で始めておく。ElastiCache Serverless はクラスタモードのクライアントで接続するため、将来キーを増やしても同じスロットに載り、マルチキー操作（`MULTI` など）ができる
- 一括削除は `HGETALL` で完了済みの ID を集め、`HDEL` に複数の field を渡して 1 コマンドで消す
- 件数の上限は 500 件とする。追加時に `HLEN` で確認し、超えたらエラーにする（デモの公開 URL が荒らされたときにデータが増え続けるのを防ぐため）

代替案と、選ばなかった理由:

- 1 件ごとの Hash（`todo:<id>`）と、並び順を持つ Sorted Set の組み合わせ: 件数が増えても強いが、デモには過剰。書き込みのたびに 2 キーの整合を保つ必要もある

### 3.6 Valkey 接続

```ts
// lib/valkey.ts（概要）
import { Cluster, Redis } from "iovalkey";

// VALKEY_CLUSTER_MODE=true（AWS）なら Cluster、false（ローカル）なら単一ノード
// AWS では TLS が必須（ElastiCache Serverless は転送中の暗号化を無効にできない）
```

| 環境変数 | AWS | ローカル |
| --- | --- | --- |
| `VALKEY_HOST` | Serverless キャッシュのエンドポイント | `127.0.0.1` |
| `VALKEY_PORT` | `6379` | `6379` |
| `VALKEY_TLS` | `true` | `false` |
| `VALKEY_CLUSTER_MODE` | `true` | `false` |

実装上の注意:

- Web Function の 1 つの実行環境は最大 64 リクエスト（デフォルト）を同時に処理する。クライアントはモジュールスコープで 1 つだけ作り、`globalThis` に保持して使い回す（開発時のホットリロードで接続が増え続けるのも防ぐ）
- Cluster モードでは `dnsLookup: (address, cb) => cb(null, address)` を指定し、TLS の SNI がエンドポイント名と一致するようにする
- 接続タイムアウトは 5 秒、コマンドタイムアウトは 3 秒に設定する。リクエストのタイムアウト（30 秒）より十分短くしておく

### 3.7 Lambda Web Functions 向けのエントリポイント

Web Functions は環境変数 `AWS_LAMBDA_HTTP_ENDPOINT`（`host:port` 形式）で待ち受けるアドレスを渡す。Next.js の standalone サーバーは `HOSTNAME` と `PORT` を読むので、変換するエントリを置く。

```js
// lambda/index.js（standalone 出力の直下にコピーする）
const address = process.env.AWS_LAMBDA_HTTP_ENDPOINT ?? "0.0.0.0:3000";
const sep = address.lastIndexOf(":");
process.env.HOSTNAME = address.slice(0, sep);
process.env.PORT = address.slice(sep + 1);
require("./server.js");
```

- ランタイムはパッケージ直下の `index.js` を既定で読み込むので、`AWS_LAMBDA_NODEJS_ENTRYPOINT` は設定しない
- standalone の `server.js` は CommonJS なので、エントリも CommonJS で書く

### 3.8 パッケージング

`scripts/package.sh` で次の手順を実行する。

1. `pnpm build`（`output: "standalone"`）
2. `public/` を `.next/standalone/public/` に、`.next/static/` を `.next/standalone/.next/static/` にコピーする
3. `lambda/index.js` を `.next/standalone/index.js` にコピーする
4. `.next/standalone/` の中身をルートに置いた zip（`dist/app.zip`）を作る

静的アセット（`/_next/static/*`）も Web Function から配信する。デモなので CloudFront は置かない。

注意点:

- pnpm の既定の `node_modules` はシンボリックリンクで構成される。standalone 出力にもリンクが残ると、zip 化や Lambda 上での解決で問題が起きる可能性がある。`.npmrc` に `node-linker=hoisted` を書いて実体ファイルで構成し、この問題を避ける
- 展開後のサイズ上限は実装時に確認する（Event Functions の 250 MB と同じ前提で、余裕を持たせる）

### 3.9 ローカル開発

```bash
docker compose up -d   # valkey/valkey:8 を 6379 で起動（TLS なし・単一ノード）
pnpm dev
```

`.env.local` に `VALKEY_HOST=127.0.0.1`、`VALKEY_TLS=false`、`VALKEY_CLUSTER_MODE=false` を書く。

## 4. Lambda Web Function の構成

| 項目 | 値 | 備考 |
| --- | --- | --- |
| 関数名 | `todo-demo` | |
| ランタイム | `nodejs24.x` | 現時点で選べるのはこれだけ |
| タイムアウト | 30 秒 | 既定値 |
| 実行環境あたりの最大同時リクエスト数 | 64 | 既定値 |
| メモリ | 2 GB（固定） | Web Functions では変更できない |
| エンドポイント名 | `prod` | |
| エンドポイントタイプ | `HomeRegion` | Network Connector を使うとこれしか選べない |
| 認可タイプ | `ApplicationManaged` | ブラウザから直接アクセスするため（`IamAuth` では SigV4 署名が必要になる） |
| 自動デプロイモード | `LatestRevision` | 新しい revision が Active になったら自動で切り替わる |
| 最大実行環境数（`maxEnvironments`） | 5 | 公開 URL への過剰アクセスで費用が膨らむのを防ぐ |
| レート制限（`rateLimit`） | 50 req/s | 同上 |
| egress | Network Connector（バージョン付き ARN） | |
| ログ | `/aws/lambda/web/todo-demo`（既定） | |

### 4.1 Web Function を Terraform で管理しない理由

Web Function 本体（関数・revision・エンドポイント）は GitHub Actions が作成・更新する。Terraform では管理しない。

- `hashicorp/aws` プロバイダには、2026-10-15 時点で Web Function のリソースがない（CloudFormation には `AWS::Lambda::WebFunction`、`WebFunctionRevision`、`WebFunctionEndpoint` がある）
- revision はイミュータブルで、デプロイのたびに新しく作るものなので、アプリのデプロイパイプラインで扱うほうが自然
- エンドポイントは `LatestRevision` モードにするので、Terraform 側で revision の重みを管理しなくてよい

選ばなかった代替案:

- `awscc` プロバイダで `AWS::Lambda::WebFunction*` を管理する: Cloud Control API 経由で作れる可能性はあるが、新しいリソース型への対応時期が読めない。さらに、revision を Terraform で作るとアプリのデプロイのたびに Terraform を実行する必要があり、「Terraform は手元で実行する」という前提と合わない
- `aws lambda-web deploy` コマンドだけで済ませる: いちばん手軽だが、`deploy` は VPC 接続（`egressNetworkConnectorArn`）に対応していない。そのため個別の API（`create-web-function` / `create-web-function-revision`）を使う

## 5. ネットワーク設計

| リソース | 値 |
| --- | --- |
| VPC | `10.0.0.0/16`（DNS サポートと DNS ホスト名を有効化） |
| private subnet a | `10.0.1.0/24`（ap-northeast-1a） |
| private subnet c | `10.0.2.0/24`（ap-northeast-1c） |
| Internet Gateway / NAT Gateway | **作らない** |

- アプリが VPC 経由で通信する相手は Valkey だけなので、NAT Gateway は要らない（固定費を避けるため）
  - Network Connector を付けると、外向き通信はすべて VPC 経由になる。将来アプリから外部 API や AWS API を呼ぶ場合は、NAT Gateway か VPC エンドポイントを追加する
  - CloudWatch Logs へのログ出力は Lambda の基盤が行うので、VPC の経路には依存しない（実装時に確認する）
- Network Connector の要件（2 つ以上の AZ のサブネット）を満たすため、サブネットを 2 つ作る

### 5.1 セキュリティグループ

| SG | 方向 | ルール |
| --- | --- | --- |
| `sg-web-connector`（Network Connector の ENI 用） | egress | TCP 6379-6380 → `sg-valkey` |
| `sg-valkey`（ElastiCache 用） | ingress | TCP 6379-6380 ← `sg-web-connector` |

## 6. Terraform 設計

### 6.1 方針

- Terraform は利用者が手元で実行する（`terraform init / plan / apply`）
- state は S3 バックエンド（`use_lockfile = true`）に置く。バケット名は `-backend-config` で渡し、コードに埋め込まない
- 環境は 1 つ（`demo`）だけ。workspace やディレクトリでの環境分割はしない

### 6.2 ディレクトリ構成

```
infra/terraform/
├── versions.tf          # terraform >= 1.10, hashicorp/aws >= 6.61
├── providers.tf         # default_tags で Project=todo-demo を付ける
├── backend.tf           # S3 backend（中身は -backend-config で渡す）
├── variables.tf
├── outputs.tf
├── network.tf           # VPC、サブネット
├── security_groups.tf
├── elasticache.tf       # aws_elasticache_serverless_cache
├── network_connector.tf # aws_lambdacore_network_connector、オペレーターロール
├── iam_web_function.tf  # Web Function の実行ロール
├── s3_artifacts.tf      # デプロイ用 zip を置くバケット
├── github_oidc.tf       # GitHub OIDC プロバイダ、デプロイ用ロール
└── terraform.tfvars.example
```

### 6.3 リソース一覧

| ファイル | リソース | 主な設定 |
| --- | --- | --- |
| network.tf | `aws_vpc`, `aws_subnet` ×2 | 5 章のとおり |
| security_groups.tf | `aws_security_group` ×2、各ルール | 5.1 節のとおり |
| elasticache.tf | `aws_elasticache_serverless_cache` | `engine = "valkey"`、`major_engine_version` は作成時点の最新、`cache_usage_limits`（データ 1 GB、ECPU 5,000/秒）で上限を設ける、`snapshot_retention_limit = 0` |
| network_connector.tf | `aws_iam_role`（オペレーターロール）, `aws_lambdacore_network_connector` | `associated_compute_resource_types = ["WebFunction"]`、`network_protocol = "IPv4"`。オペレーターロールは `ec2:CreateNetworkInterface` と、条件付きの `ec2:CreateTags` を持つ |
| iam_web_function.tf | `aws_iam_role` | 信頼ポリシーは `lambda.amazonaws.com`。CloudWatch Logs への書き込みを許可する。ENI 関連の権限は付けない（オペレーターロールが持つため） |
| s3_artifacts.tf | `aws_s3_bucket` ほか | バージョニング有効（revision が特定のオブジェクトバージョンを参照するため）、パブリックアクセスブロック、SSE-S3、古いバージョンを 30 日で削除するライフサイクル |
| github_oidc.tf | `aws_iam_openid_connect_provider`、`aws_iam_role` | 信頼条件は `repo:<owner>/<repo>:ref:refs/heads/main`。OIDC プロバイダがアカウントに既にある場合に備え、`create_github_oidc_provider` 変数で作成を切り替える |

### 6.4 変数

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `region` | `ap-northeast-1` | |
| `project` | `todo-demo` | リソース名の接頭辞 |
| `github_repository` | （必須） | `owner/repo` 形式 |
| `create_github_oidc_provider` | `true` | OIDC プロバイダが既にあれば `false` |
| `web_function_name` | `todo-demo` | IAM ポリシーのリソース ARN を絞るために使う |

### 6.5 出力（GitHub Actions の Variables に登録する）

| 出力 | GitHub Variable | 用途 |
| --- | --- | --- |
| `aws_region` | `AWS_REGION` | |
| `deploy_role_arn` | `AWS_DEPLOY_ROLE_ARN` | OIDC で AssumeRole するロール |
| `artifact_bucket` | `ARTIFACT_BUCKET` | zip のアップロード先 |
| `web_function_execution_role_arn` | `WEB_FUNCTION_ROLE_ARN` | revision の `executionRoleArn` |
| `network_connector_arn` | `NETWORK_CONNECTOR_ARN` | **バージョン付き** ARN（`...:network-connector:<id>:<version>`） |
| `valkey_endpoint` | `VALKEY_HOST` | revision の環境変数 |

いずれも秘密情報ではないので、Secrets ではなく Variables に登録する。

### 6.6 デプロイ用ロールの権限（GitHub Actions）

| 権限 | リソース |
| --- | --- |
| `s3:PutObject`, `s3:GetObjectVersion` | アーティファクトバケット |
| Web Function の作成・取得・revision 作成・エンドポイント取得、`wait` に必要な取得系 API | `todo-demo` 関数 |
| `lambda:PassNetworkConnector` | 対象の Network Connector |
| `iam:PassRole` | Web Function の実行ロール（条件 `iam:PassedToService = lambda.amazonaws.com`） |

Web Function 操作の IAM アクション名（`lambda:CreateWebFunction` など）は、実装時にサービス認可リファレンスで確認して確定させる。

## 7. CI/CD 設計（GitHub Actions）

### 7.1 ワークフロー

| ファイル | トリガー | 内容 |
| --- | --- | --- |
| `.github/workflows/ci.yml` | pull_request、main 以外への push | `pnpm install --frozen-lockfile` → `biome ci` → `tsc --noEmit` → `pnpm build` |
| `.github/workflows/deploy.yml` | main への push、`workflow_dispatch` | 7.2 節のとおり |

### 7.2 deploy.yml の流れ

```
1. checkout
2. pnpm / Node.js 24 をセットアップ
3. pnpm install --frozen-lockfile
4. biome ci / tsc --noEmit
5. scripts/package.sh            → dist/app.zip
6. aws-actions/configure-aws-credentials（OIDC）
7. aws s3 cp dist/app.zip s3://$ARTIFACT_BUCKET/todo-demo/${GITHUB_SHA}.zip
   → レスポンスの VersionId を取得
8. aws lambda-web get-web-function --function-name todo-demo
   ├─ 存在しない → create-web-function
   │                 （revision-config と endpoint-config を同時に指定）
   └─ 存在する   → create-web-function-revision
9. revision が Active になるまで待つ（aws lambda-web wait ...）
10. エンドポイント URL を取得し、GET /api/health でスモークテスト
11. Job Summary に URL と revision ID を書く
```

- 依存パッケージは純 JS なので、x86_64 の `ubuntu-latest` でビルドしても arm64 で動く。ネイティブモジュールを追加する場合は `ubuntu-24.04-arm` ランナーに切り替える
- `concurrency: deploy-prod` を設定し、デプロイを直列に実行する
- revision の `description` には `${GITHUB_SHA}` を入れ、どのコミットか追えるようにする
- 環境変数（`VALKEY_*`、`NODE_ENV=production`）は revision の `serviceConfig.environmentVariables` で渡す
- create 系の JSON は `jq` で組み立て、`--cli-input-json` で渡す
- Web Functions の API は最近追加されたので、ランナーの AWS CLI が古い可能性がある。ワークフローで AWS CLI v2 の最新版をインストールしてから使う

### 7.3 ロールバック

- `LatestRevision` モードのエンドポイントを、`update-web-function-endpoint --auto-deployment-mode Disabled --revision-weights '[{"revisionId":"<前の revision>","weight":100}]'` で前の revision に固定する
- 修正をデプロイしたら、`LatestRevision` モードに戻す
- 手順は README に書く。ワークフロー化はしない（デモのため）

## 8. 構築・撤去の手順

### 8.1 初回構築

1. GitHub リポジトリを作り、コードを push する
2. `infra/terraform/terraform.tfvars` を作る（`github_repository` などを設定する）
3. `terraform init -backend-config=...` → `terraform apply`
4. `terraform output` の値を GitHub の Repository Variables に登録する
5. main に push する（または deploy.yml を手動で実行する）→ Web Function が作られる
6. Actions の Job Summary に出た URL にアクセスして動作を確認する

### 8.2 撤去

Network Connector は、参照している revision が残っていると安全に消せない。そのため、先に Web Function を消す。

1. `aws lambda-web delete-web-function --function-name todo-demo`（`scripts/destroy-web-function.sh` を用意する）
2. `terraform destroy`

## 9. セキュリティ

| 観点 | 対応 |
| --- | --- |
| エンドポイントの公開範囲 | `ApplicationManaged` なので誰でもアクセスできる。デモであることを画面に明記する。必要になれば、Next.js の middleware で Basic 認証を足せるようにしておく（環境変数 `BASIC_AUTH` が設定されているときだけ有効にする） |
| 費用と荒らし対策 | エンドポイントの `maxEnvironments`、`rateLimit`、Valkey の `cache_usage_limits`、TODO の件数上限（500 件）の 3 段で上限を設ける |
| Valkey | VPC 内に置く。TLS は必須。SG で Connector の ENI からの接続だけを許可する |
| CI の認証情報 | OIDC で一時的な認証情報を使う。main ブランチからしか AssumeRole できない |
| 入力値 | Server Action で zod を使って検証する。React の既定のエスケープで XSS を防ぐ |
| CSRF | Server Actions の Origin ヘッダ検証（Next.js 標準）に任せる |

## 10. 費用の目安（東京リージョン、アイドル時の概算）

| 項目 | 目安 |
| --- | --- |
| ElastiCache Serverless for Valkey | 最小課金のデータ量で月 6〜7 USD 程度 + ECPU（デモのアクセス量ならわずか） |
| Lambda Web Functions | アクティブな CPU 時間とメモリへの従量課金。アイドル時はゼロまでスケールする |
| S3、CloudWatch Logs | 数十セント程度 |
| NAT Gateway | なし（0 USD） |

単価は実装時に料金ページで再確認する。

## 11. リスクと未確認事項

| # | 内容 | 対応 |
| --- | --- | --- |
| R1 | Lambda Web Functions は GA 直後で、事例と情報が少ない | 最小構成（health エンドポイントのみ）で、Connector 経由の Valkey 接続を最初に確かめる |
| R2 | `aws_lambdacore_network_connector` の属性名（バージョン付き ARN の取り出し方など） | 実装時にプロバイダのドキュメントで確認する。バージョン番号を取れない場合は、`terraform output` の後に `aws lambda-core get-network-connector` で確定させる手順にする |
| R3 | Web Function 操作の IAM アクション名 | 6.6 節のとおり、実装時に確定させる |
| R4 | pnpm と Next.js standalone、zip の相性（シンボリックリンク） | `node-linker=hoisted` で避ける（3.8 節） |
| R5 | VPC 接続した revision のログ出力経路 | 最初のデプロイで CloudWatch Logs に出ることを確認する |
| R6 | ElastiCache Serverless にクラスタモードのクライアントで TLS 接続する際の設定 | 3.6 節の `dnsLookup` 設定で対応する。R1 の検証と一緒に確認する |

## 12. 選ばなかった構成

ネットワーク構成の選択肢（VPC を使うか、内部用 API をどう作るか）は [network-options.md](./network-options.md) に図で整理した。

| 案 | 選ばなかった理由 |
| --- | --- |
| ElastiCache Serverless の **パブリックエンドポイント**（Valkey 9 以上、IAM 認証が必須） | VPC と Network Connector が不要になり、構成はかなり簡単になる。ただし、IAM 認証トークン（有効期限 15 分）の生成と再接続を実装する必要があり、データストアがインターネットに露出する。今回は「Web Function から VPC 内リソースへ接続する」ことを検証したいので、VPC 構成を採る |
| Event Functions + Lambda Web Adapter / OpenNext | 指定が Web Functions であり、Web Functions ならアダプタが不要 |
| CloudFront を前段に置く | カスタムドメインやキャッシュはデモに不要。後から OAC 付きで追加できる |
| ユーザー認証（Cognito など） | デモの目的（基盤の検証）から外れる |

## 13. 実装の進め方

1. Next.js プロジェクトの雛形を作る（pnpm、Biome、standalone 出力、`lambda/index.js`、health API）
2. Terraform 一式を作る → 利用者が apply する
3. deploy.yml を作り、health API だけの状態でデプロイし、Connector 経由の Valkey 疎通を確かめる（R1、R5、R6 を解消する）
4. TODO 機能（F1〜F7）を実装する
5. README（構築・撤去・ロールバックの手順）を整える
