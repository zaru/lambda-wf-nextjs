# 作業メモ（2026-10-16 時点）

設計書や調査ドキュメントに書いていない事項のメモ。検証を再開するときに読む。

## 1. 現在の状態

**2026-10-16 に撤去済み。** AWS のリソースは `scripts/destroy-web-function.sh` と `terraform destroy` で削除し、GitHub リポジトリの Variables（13 件）も削除した。費用は発生していない。

### 再開するときの手順

README の「構築」の手順を最初からやり直す。撤去前と比べて、次の点が変わる。

- エンドポイントのホスト名、CloudFront のディストリビューション、Network Connector などは、すべて新しい値になる
- `infra/terraform/terraform.tfvars` には撤去前のエンドポイントのホスト名が残っているので、1 回目の apply の前に消すか、`web_function_endpoint_domain = ""` にする（残したままだと、存在しないオリジンで CloudFront が作られる）
- GitHub の Variables は、README の手順 2 で登録し直す

### 撤去前の構成の記録

| 項目 | 値 |
| --- | --- |
| アプリの URL | `https://wf.dev.id.basicinc.jp`（DNS レコードも削除済み） |
| Web Function | `wf-proto-todo`（エンドポイント `prod`、`HomeRegion` / `IamAuth` / `LatestRevision`） |
| AWS アカウント / リージョン | 881893826735 / `ap-northeast-1` |

### 手元にだけあるもの（コミットしていない）

| ファイル | 内容 |
| --- | --- |
| `infra/terraform/terraform.tfstate` | 撤去後の state（リソースは空）。消してもよい |
| `infra/terraform/terraform.tfvars` | 撤去前のエンドポイントのホスト名。再開前に消すか空にする |
| `loadtest/results/*` | k6 の結果の JSON と、コールドスタートの CSV。要約は `docs/results/2026-10-16.md` にある |

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
