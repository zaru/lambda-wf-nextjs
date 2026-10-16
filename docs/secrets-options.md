# Web Functions への秘匿情報の渡し方

調査日: 2026-10-16

## 1. 現状の実装

Secrets Manager に保存した値を、アプリが実行時に自分で取得している。

| 層 | 内容 | 場所 |
|---|---|---|
| 保存 | Valkey のパスワードを Secrets Manager に置く | `infra/terraform/secrets.tf` |
| 権限 | 実行ロールに、そのシークレット 1 つだけの `secretsmanager:GetSecretValue` を許可する | `infra/terraform/iam_web_function.tf` |
| 参照先の受け渡し | 環境変数 `VALKEY_SECRET_ARN` に ARN だけを入れる（値は入れない） | `scripts/deploy.sh` |
| 取得 | AWS SDK で `GetSecretValue` を呼び、メモリに保持する | `lib/secrets.ts`、`lib/valkey.ts` |

- 取得の経路は、Network Connector → NAT Gateway → Secrets Manager
- 取得は、最初の Valkey 接続時の 1 回だけ。コールドスタートに、この取得時間が上乗せされる
- 環境変数に入れているのは、ホスト名、ポート、ユーザー名、ARN といった秘匿でない値だけ

## 2. Web Functions 側で確認できたこと

`aws lambda-web create-web-function-revision help` で確認した内容。

- `environmentVariables`: 「環境変数の値は sensitive」と書かれている
- `kmsKeyArn`: revision のコードと環境変数の暗号化に使う KMS キー

Web Functions 固有の Secrets 連携（ECS の `secrets` のような、基盤が値を解決して注入する仕組み）は、ヘルプに見当たらなかった。AWS ドキュメントの検索でも、Web Functions 向けの記述は見つかっていない。

## 3. 渡し方の選択肢

以下は、通常の Lambda の知識を前提にした整理。Web Functions での対応は、特記がない限り未確認。

| # | 方法 | 長所 | 短所 |
|---|---|---|---|
| 1 | 環境変数に値を直接入れる | 最も簡単 | 値が revision の設定に残る。`kmsKeyArn` で自前の KMS キーを指定し、参照できる人を絞る。ローテーションのたびに新しい revision のデプロイが必要 |
| 2 | アプリが実行時に Secrets Manager から取得する（現状） | 値が設定に残らない。IAM と CloudTrail で追跡できる。再取得を実装すれば、再デプロイなしでローテーションを反映できる | コールドスタートが増える。NAT や VPC エンドポイントへの依存がある |
| 3 | SSM Parameter Store（SecureString）から取得する | 仕組みは 2 と同じ。標準パラメータなら無料枠がある | ローテーションの機能がない |
| 4 | Parameters and Secrets Lambda Extension を使う | 通常の Lambda では、ローカルキャッシュ付きで取得できる | Web Functions がレイヤーや拡張に対応しているか未確認 |
| 5 | デプロイ時に取得して環境変数に展開する | 実行時の取得が不要 | 値が設定に残る（1 と同じ弱点）。デプロイを実行する CI が値を読める必要がある |

## 4. ECS Fargate との違い

ECS の `secrets` は、起動時にコンテナ基盤が値を解決して環境変数に注入する。Web Functions にはこれに相当する機能が見当たらないため、次のどちらかになる。

- アプリ側で取得する（現状の方式）
- デプロイ時に展開する

## 5. 判断

このアプリのパスワードは、現状の方式（2）で十分。ただし、起動のたびに NAT 経由の呼び出しが 1 回入る。結果ドキュメントのコールドスタートの内訳で、秘密取得の分を確認しておく。

## 6. 未確認事項

- Web Functions が Secrets Manager や Parameter Store の値を直接注入する機能を持つか（公式ユーザーガイドでの確認が必要）
- Web Functions がレイヤーや Lambda 拡張に対応しているか
