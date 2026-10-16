# 作業メモ（2026-10-16 時点）

設計書や調査ドキュメントに書いていない事項のメモ。検証を再開するときに読む。

## 1. 現在の状態

### AWS（`ap-northeast-1`、アカウント 881893826735）

**リソースは稼働中で、アイドル時でも月約 60 USD かかる**（NAT Gateway が約 45 USD）。しばらく再開しない場合は、README の「撤去」の手順で削除する。

| 項目 | 値 |
| --- | --- |
| アプリの URL | `https://wf.dev.id.basicinc.jp` |
| Web Function | `wf-proto-todo`（エンドポイント `prod`、`HomeRegion` / `IamAuth` / `LatestRevision`） |
| エンドポイントのホスト名 | `w7r840p0ss22m5j3.6jm.lambda-web.ap-northeast-1.on.aws` |
| CloudFront | `E3SHIJEMG0RVDV`（`d191m3kzrevbcz.cloudfront.net`） |
| NAT Gateway の送信元 IP | `13.230.211.57` |
| Network Connector | `nc-7b775a16-8508-4100-89b3-cf09862a5f47`（バージョン 1） |

### 手元にだけあるもの（コミットしていない）

| ファイル | 内容 | なくした場合 |
| --- | --- | --- |
| `infra/terraform/terraform.tfstate` | Terraform の state。Valkey のパスワードが平文で入っている | `terraform destroy` で消せなくなる。AWS コンソールなどで手作業で消すことになる |
| `infra/terraform/terraform.tfvars` | `web_function_endpoint_domain`（上のホスト名） | 上の表の値で作り直せる |
| `loadtest/results/*` | k6 の結果の JSON と、コールドスタートの CSV | 要約は `docs/results/2026-10-16.md` にある |

### データ

アプリの TODO リストに、計測で作ったデータが残っている。

- `loadtest seed 1`〜`30`（k6 の準備処理で追加したもの）
- `動作確認（CloudFront 経由）`

画面の「完了済みを一括削除」などで消せる。

## 2. Valkey の認証方式（未決定）

現在はパスワード認証（RBAC ユーザー ＋ Secrets Manager）。コールドスタートの改善を検討する中で、次の 3 案を比べた。

| 観点 | 認証なし | パスワード（現在） | IAM 認証 |
| --- | --- | --- | --- |
| 守り方 | ネットワークだけ（Private Subnet と SG） | ネットワーク ＋ パスワード | ネットワーク ＋ IAM |
| コールドスタートへの影響 | なし | Secrets Manager の取得（85〜260ms） | トークンの生成（手元での署名だけで、ネットワークの往復なし） |
| 秘密情報の管理 | 不要 | 必要（Secrets Manager、Terraform の state に平文） | 不要 |
| 権限を絞れるか | できない（`FLUSHALL` なども通る） | できる（今は `{todo}:*` だけ、危険なコマンドは禁止） | できる |
| 実装の手間 | 最小 | 中（実装済み） | 多い（15 分で切れるトークンを、再接続のたびに作り直す処理が必要。接続は最長 12 時間で切れる） |

- ElastiCache Serverless は、ユーザーグループを付けなければ認証なしで接続できる。TLS は無効にできない
- 今回の構成では、Valkey に届くのは Network Connector の SG からの通信だけ（VPC は既存環境から分離している）なので、認証なしでも実質的にこの Web Function しか使えない。ただし防御が 1 層になり、最小権限にもできない
- 「本番に近い形で検証する」目的には、IAM 認証が最も合っている。認証なしは、コールドスタートへの影響を比べるために一時的に試す価値はある

秘密情報の渡し方そのものの比較は [secrets-options.md](./secrets-options.md) を参照。

## 3. 残っている課題と次の候補

| 項目 | 状態 | 参照 |
| --- | --- | --- |
| Valkey の認証方式（上の 2 章） | 未決定 | |
| コールドスタートの改善（取得の開始を早める、IAM 認証） | 候補を記録しただけ | `results/2026-10-16.md` の 7 章 |
| 何分でゼロまでスケールインするか | 不明（1 回目は 5 分で残り、2 回目は 5 分で入れ替わった）。ボットのアクセスも混ざる | `results/2026-10-16.md` の 6.3 節、7 章 |
| スケールアウトの観察 | 軽量なシナリオのまま。実行環境あたりの最大同時リクエスト数を下げて観察する方法がある | 設計書 9.4 節 |
| 負荷試験の合格基準 | 未決定 | 設計書 14 章の Q6 |
| ボットからのアクセス | 公開から数時間で、脆弱性を探すアクセスが来た（すべて 404）。WAF はスコープ外にしている | `results/2026-10-16.md` の 6.3 節 |
| デプロイ中の新旧 revision の混在 | 調査済み、実測は未実施 | [deploy-mixing.md](./deploy-mixing.md) |

## 4. 作業中に踏んだ落とし穴

ドキュメントのリスク表（設計書の R11〜R13）に書いたもの以外。

| 事象 | 原因と対処 |
| --- | --- |
| Logs Insights でアプリのログ（`warmup completed` など）が項目で検索できない | Lambda のランタイムが、`console.log` の出力を `{"timestamp", "level", "message": "<元の文字列>"}` に包むため。`lib/logger.ts` を `process.stdout.write` に直した（2026-10-16 のデプロイ以降）。それ以前のログは `@message like /.../` で検索する |
| ローカルで起動した Next.js のサーバーが `pkill -f ".next/standalone/index.js"` で止まらない | Next.js が起動時にプロセス名を `next-server` に書き換えるため。起動したシェルで `$!` の PID を控えて `kill` する |
| zsh のループで `for path in ...` と書くと、以降のコマンドが見つからなくなる | zsh では `path` が環境変数 `PATH` と連動している。別の変数名を使う |
| `terraform apply` で `lookup cloudfront.amazonaws.com: no such host` | 手元の DNS の一時的な失敗。再実行で通った。繰り返す場合は `GODEBUG=netdns=cgo terraform apply` |
| 手元の AWS CLI（2.32.6）に `lambda-web` コマンドがない | `lambda-web` / `lambda-core` は新しいコマンド。CLI を最新版に更新する。GitHub Actions では、ワークフローの中で毎回更新している |
| GitHub Actions のログに `Detected a pnpm v10 installation layout at PNPM_HOME` の警告が出る | `pnpm/action-setup` の環境に起因する警告で、動作には影響しない（未対応） |
