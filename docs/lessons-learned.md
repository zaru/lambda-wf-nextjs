# Lambda Web Functions 検証のまとめ（Terraform / Next.js）

- 作成日: 2026-10-19
- 対象: 2026-10-15〜16 に実施した検証（2026-10-16 に撤去済み）
- 位置づけ: 設計書・調査ドキュメント・計測結果・作業メモに散らばっている知見を、1 か所に集約したもの。詳細は各ドキュメントを参照する

| 参照先 | 内容 |
| --- | --- |
| [design.md](./design.md) | 設計と、リスクの解消状況（13 章） |
| [network-options.md](./network-options.md) | ネットワーク構成の選択肢 |
| [secrets-options.md](./secrets-options.md) | 秘匿情報の渡し方 |
| [deploy-mixing.md](./deploy-mixing.md) | デプロイ中の新旧 revision の混在 |
| [results/2026-10-16.md](./results/2026-10-16.md) | 計測結果 |
| [notes.md](./notes.md) | 状態、未決定事項、落とし穴 |

## 1. 総括

- **Next.js（App Router、Server Actions）は、アダプタなしで Web Functions にそのまま載った。** 構成は CloudFront（OAC）→ Web Function（`IamAuth`）→ Network Connector → ElastiCache Serverless for Valkey。NAT Gateway 経由の外部通信（祝日 API、Secrets Manager）も動いた
- 計測したすべてのシナリオ（最大 50 rps）でエラーは 0 件だった。ウォーム時のサーバー内処理は 5ms 前後で、クライアントから見た `GET /` は med 20〜27ms
- 本当のコールドスタートは、TTFB で **1.2〜1.9 秒**。アプリ側でコントロールできるのは、このうち約 250ms（初期化）だけだった
- 一方で、ドキュメントからは読み取りにくい要件が構築中に 3 つ見つかった（4.3 節）。Terraform プロバイダに Web Function のリソースがないことも、設計に影響した（3.1 節）
- 費用は、アイドル時で月 60 USD 程度と見積もった。**大半は NAT Gateway（約 45 USD）で、Web Functions 自体の固定費ではない**

## 2. Web Functions の仕組みで分かったこと

### 2.1 ネットワークモデル

詳細は [network-options.md](./network-options.md)。

- 受信は常に公開の HTTPS エンドポイントで、閉域にできない（PrivateLink 非対応）。`IamAuth` にしても、ネットワークとしては公開のまま
- 送信は revision ごとに「Connector なし（直接インターネットへ）」か「Connector あり」を選ぶ。Connector ありにすると**すべて**の外向き通信が VPC を通り、Connector 自体は出口にならない。宛先ごとの振り分けはできない
- Connector を使えるのは `HomeRegion` エンドポイントだけ
- 構成は「VPC 内のリソースに届きたいか」と「外部通信をしたいか」の 2 軸で決まる。両方なら Connector ＋ NAT Gateway
- **見落としやすい外部通信**: Connector を使うと、Secrets Manager、SSM、OIDC の JWKS、`next/image` の外部画像、Sentry などの監視も NAT 越えになる。今回も、秘密情報の取得が NAT 経由になり、コールドスタートに効いた

### 2.2 実行モデル

- 起動するプロセスは、ふつうの HTTP サーバー。Lambda が `AWS_LAMBDA_HTTP_ENDPOINT`（`host:port`）を渡すので、それを standalone の `server.js` が読む `HOSTNAME` と `PORT` に変換する 4 行（`lambda/index.js`）だけで Next.js が動いた
- メモリは 2 GB で固定。1 つの実行環境が複数のリクエストを同時に処理する（既定は最大 64）。このため、Valkey のクライアントは実行環境ごとに 1 つだけ作って使い回す設計にした
- ログは、リージョン内の `<name>.local` に書かれてから、ホームリージョンの `<name>` に集約される。Terraform で両方のロググループを先に作っておく。Logs Insights で結果が空のときは `.local` を見る
- **ランタイムが `console.log` の出力を `{"timestamp","level","message":"<元の文字列>"}` に包む。** アプリが出す JSON は文字列になり、項目で検索できない。`process.stdout.write` で書くと JSON のまま出る

### 2.3 スケーリング

- 負荷が 10 rps でも、実行環境は 6〜8 個に分かれた（「1 つで処理しきれる」という当初の予想は外れた）。需要に先回りして実行環境を用意する動き（ヘッドルーム）があり、公式ドキュメントにも記載がある
- そのため、ログの `coldStart=1`（その実行環境での最初のリクエスト）は、**利用者がコールドスタートを体験したことを意味しない**。5 分前に起動した実行環境が最初のリクエストを受けることもある。区別するため、待ち受けの開始から最初のリクエストまでの時間（`sinceReadyMs`）をログに出した（数百 ms なら起動を待っていた）
- **何分でゼロまでスケールインするかは、結論が出なかった。** 1 回目の計測は 5 分後も実行環境が残り、2 回目は 5 分で入れ替わった。公開されている情報はなく、ボットのアクセスも計測に混ざる

### 2.4 デプロイとトラフィックの切り替え

詳細は [deploy-mixing.md](./deploy-mixing.md)。

- `LatestRevision`: revision が Active になると、100% が自動で切り替わる。`Disabled`: 切り替わらず、revision weights（最大 2 revision、合計 100）で手動制御する。カナリアはこちら
- 更新は非同期なので、`updateStatus` が `Successful` になるまで待つ必要がある
- トラフィックを受けている revision は削除できない
- メトリクスに revision の次元がない。カナリアの切り分けには、アプリのログにビルド ID を入れる必要がある
- **未確認**: `LatestRevision` の切り替えの瞬間に、新旧が混ざる時間の長さと 5xx の有無。旧 revision の処理中のリクエストが完了まで待たれるか。いずれも公式ドキュメントに記載がなく、実測もしていない

### 2.5 秘匿情報

詳細は [secrets-options.md](./secrets-options.md)。

- 環境変数は sensitive 扱い。`kmsKeyArn` で暗号化キーを指定できる
- ECS の `secrets` のような、基盤が値を解決して注入する仕組みは見当たらなかった。アプリが自分で取得するか、デプロイ時に展開するかのどちらかになる
- 今回は、アプリが Secrets Manager から取得する方式にした。その代償が、コールドスタートでの取得時間（NAT 経由で 85〜260ms）
- 未確認: Secrets Manager / Parameter Store の直接注入、レイヤーや Lambda 拡張への対応

## 3. Terraform で分かったこと

### 3.1 Web Function 本体は Terraform で管理できない（2026-10-16 時点）

- `hashicorp/aws` に、Web Function（関数、revision、エンドポイント、リソースポリシー）のリソースがない。Network Connector だけが `aws_lambdacore_network_connector`（6.61.0 で追加）にある
- revision は変更できないリソースで、デプロイのたびに新しく作る。そのため、Terraform は「土台」（VPC、Valkey、Connector、IAM、S3、CloudFront、DNS、ログ）、GitHub Actions は「アプリ」（revision とエンドポイント）と分けた
- 選ばなかった案: `awscc` プロバイダ（新しいリソース型への対応時期が読めず、デプロイのたびに Terraform を実行する形になる）、`aws lambda-web deploy` のみ（VPC 接続の指定に対応していない）
- Connector の**バージョン付き ARN** を取り出す属性は Terraform になかった（`arn` のみ）。デプロイ時に `get-network-connector` の `LatestVersionArn` を調べる方式にした

### 3.2 2 段階の apply が必要になる

CloudFront のオリジンには、Web Function のエンドポイントのホスト名が要る。エンドポイントは初回デプロイで作られるので、次の順番になる。

1. 1 回目の apply（`web_function_endpoint_domain` は空。CloudFront は作らない）
2. GitHub の Variables を登録して、初回デプロイ
3. エンドポイントのホスト名を tfvars に書いて 2 回目の apply（CloudFront、OAC、Route 53）
4. `DISTRIBUTION_ARN` を登録し直して再デプロイ（リソースポリシーで CloudFront を許可）

`count` で CloudFront 関連のリソースを切り替えている。**撤去後に再構築するときは、tfvars に古いホスト名を残さない**（存在しないオリジンで CloudFront が作られる）。

### 3.3 その他

- Network Connector の作成に 10 分ほどかかる
- 撤去は順番が大事。Connector を参照する revision を先に消す必要があるので、`scripts/destroy-web-function.sh` で Web Function を消してから `terraform destroy` する
- state をローカルに置く場合、なくすと destroy できず、NAT Gateway などの費用が出続ける。state には Valkey のパスワードが平文で入る
- 既存のアカウントに相乗りする場合、VPC を完全に分離し、state も別にして、既存の GitHub OIDC プロバイダは `data` で参照して共用した
- `aws_cloudfront_origin_access_control` は `always-amz-auth` を受け付けた（provider 6.69.1）
- `terraform apply` で `lookup cloudfront.amazonaws.com: no such host` が出たのは、手元の DNS の一時的な失敗だった。再実行で通る。繰り返すなら `GODEBUG=netdns=cgo`

## 4. IAM・認証まわりの落とし穴

構築中に詰まった点。ドキュメントを読むだけでは気づきにくく、**再現する可能性が高い**。

| # | 事象 | 原因と対処 |
| --- | --- | --- |
| 1 | Network Connector の作成が「ロールを引き受けられない」で失敗する | オペレーターロールの信頼ポリシーに `aws:SourceAccount` 条件を付けたため。ドキュメントの例どおり条件なしにした。ロールの作成直後は反映待ちがあるので、30 秒待ってから Connector を作る |
| 2 | GitHub Actions の OIDC で AssumeRole できない | トークンの `sub` が、リポジトリの不変 ID を含む形式（`use_immutable_subject`）だった。信頼ポリシーをその形式に合わせた |
| 3 | revision の作成が失敗する | 作成時に Lambda サービス自身がパッケージを S3 から読めることが求められる。バケットポリシーで `lambda.amazonaws.com` に読み取りを許可した（`aws:SourceArn` でこの関数の revision に限定）。デプロイ用ロールにも `s3:GetObject` が必要（呼び出し元の権限でも読まれる） |
| 4 | IAM アクション名が分からない | 網羅した資料がなかった。`lambda:*WebFunction*` を関数の ARN に絞って許可して通った。ほかに `lambda:PassNetworkConnector`、`lambda:GetNetworkConnector`、`iam:PassRole` が要る |

## 5. CloudFront との組み合わせ

- Web Functions は独自ドメインに直接対応していないので、CloudFront と独自ドメインが必要になる
- OAC は `sigv4` ＋ `always-amz-auth`。エンドポイントのリソースポリシーで、`cloudfront.amazonaws.com` に `lambda:InvokeWebFunctionEndpoint` を許可し、`aws:SourceArn` を自分のディストリビューションに限定する。これでエンドポイントへの直接アクセスを拒否できた
- **`Host` ヘッダは転送しない。** エンドポイントは `Host` でルーティングするため、ディストリビューションのドメイン名を送ると 404 になる。`AllViewerExceptHostHeader` を使う
- POST（Server Actions）は `UNSIGNED-PAYLOAD` で署名される。クライアントでハッシュを計算する必要はなかった
- OAC を付けたビヘイビアでは Lambda@Edge のオリジンリクエスト / レスポンスのトリガーが使えない
- 静的ファイルは `/_next/static/*` だけを `CachingOptimized` にし、残りは `CachingDisabled`。静的ファイルの med は 6ms で、動的なリクエストの比較の基準になった
- 公開してから数時間で、脆弱性を探すボットのアクセスが来た（すべて 404）。証明書の発行記録からドメインが見つかったと考えられる。WAF をスコープ外にしたが、公開するなら考える必要がある

## 6. Next.js で分かったこと

### 6.1 動かすための要点

| 項目 | 内容 |
| --- | --- |
| 出力形式 | `output: "standalone"`。`public/` と `.next/static/` をコピーし、`lambda/index.js` を直下に置いて zip にする |
| pnpm | 既定の `node_modules` はシンボリックリンクなので、zip で壊れる。`pnpm-workspace.yaml` に `nodeLinker: hoisted` を書く（pnpm 10 以降は `.npmrc` ではなくここに書く） |
| ネイティブモジュール | arm64 向けのビルドで困らないよう、Valkey のクライアントは純 JS の `iovalkey` にした（公式の `valkey-glide` はネイティブモジュールを含む） |
| レンダリング | Web Function は複数の実行環境にスケールし、Next.js のキャッシュは環境ごとに独立する。表示がずれないよう、`force-dynamic` で Next.js のキャッシュを使わず、リクエストごとに Valkey から読む |
| データ更新 | Server Actions で書き込み、`revalidatePath("/")`。画面側は `useOptimistic` |

### 6.2 Server Actions の Origin 検証

CloudFront は `Host` を Web Function のエンドポイント名で送る。ブラウザの `Origin`（独自ドメイン）と食い違い、Next.js が Server Actions を拒否する。`next.config.ts` の `serverActions.allowedOrigins` に独自ドメインを指定すると動いた。

### 6.3 ElastiCache Serverless for Valkey への接続

- クラスタモードと TLS が前提（TLS は無効にできない）。ローカルは単一ノード・TLS なしなので、環境変数で切り替える
- クラスタモードでは、`dnsLookup: (address, cb) => cb(null, address)` を指定して、TLS の SNI がエンドポイント名と一致するようにする
- キーに `{todo}` のようなハッシュタグを付けて同じスロットにまとめると、マルチキー操作ができる
- ACL の `-@dangerous` でも、クラスタモードのクライアントは読み書きできた。ユーザーグループに `default` ユーザーがなくても作成でき、アプリ用ユーザーで接続できた
- 認証方式は未決定（[notes.md](./notes.md) 2 章）。パスワード、認証なし、IAM 認証を比べると、IAM 認証が「本番に近い形」には合うが、15 分で切れるトークンの作り直しと、接続が最長 12 時間で切れることへの対応が要る

### 6.4 ローカルでの確認

- `lambda/index.js` 経由で起動すると、Web Functions と同じ起動方法を手元で確かめられる（`AWS_LAMBDA_HTTP_ENDPOINT=127.0.0.1:3000`）
- Next.js は起動時にプロセス名を `next-server` に書き換えるので、`pkill -f ".next/standalone/index.js"` では止まらない。起動時の `$!` の PID を控えて `kill` する
- 手元の AWS CLI が古いと `lambda-web` コマンドがない。最新版に更新する

## 7. 性能の知見

計測元は東京の手元のマシン、CloudFront 経由。表の値の単位は ms。詳細は [results/2026-10-16.md](./results/2026-10-16.md)。

### 7.1 ウォーム時

| 対象 | med | p95 | p99 |
| --- | --- | --- | --- |
| `GET /`（SSR ＋ Valkey） | 27.2 | 60.4 | 93.3 |
| Server Action | 25.2 | 43.7 | 97.6 |
| `GET /api/health`（Valkey の PING） | 20.6 | 33.3 | 60.6 |
| `GET /_next/static/*`（CloudFront のキャッシュ） | 6.2 | 10.5 | 15.7 |
| `GET /api/diag/external`（NAT 経由で祝日 API） | 38.7 | 93.3 | 112.0 |

- サーバー内の処理は 5ms 前後（Valkey が 3〜5ms）。クライアントから見た時間の大半は、CloudFront とオリジンのあいだの経路と、そこへの往復
- 10 → 50 rps で、中央値と p95 はほとんど変わらなかった。エラーは 0 件
- max の 250〜330ms は、すべて新しい実行環境の最初のリクエスト（Valkey への初回接続）だった

### 7.2 コールドスタート（TTFB 1.2〜1.9 秒）

60 分アイドル後の内訳（TTFB 1,622ms）:

| 段階 | 時間 | 制御できるか |
| --- | --- | --- |
| ① 実行環境の準備（microVM の起動など。推定） | 約 640ms | できない |
| ② Node.js と Next.js の起動（listen まで） | 440ms（どの環境でも 316〜454ms） | 一部できる（依存を減らすなど） |
| ③ 待ち受けの検知から、リクエストが届くまで | 約 255ms | できない（内部の仕組みは非公開） |
| ④ 最初のリクエストの処理 | 251ms | できる |
| ネットワーク | 約 40ms | — |

④ の内訳は、Secrets Manager の取得 85ms（NAT 経由）、Valkey の最初のコマンド 66ms（各ノードへの接続）、Valkey への接続 約 8ms、残り 約 92ms（Next.js の初回処理）。

- **画面（`/`）の初回表示も遅い。** 同じ実行環境での 2 リクエスト目でも、サーバー total が 133〜145ms かかった
- **5 分アイドルの後のウォーム時でも、TTFB に 100ms 前後の上乗せがあった。** CloudFront とオリジンのあいだの接続を作り直したためと考えられる

### 7.3 改善を試して分かったこと

`instrumentation.ts` の `register()` で、Secrets Manager の取得と Valkey への接続をバックグラウンドで始める改善を実装して、同じ条件で計測し直した。

- サーバー内の処理は 250ms → 145〜196ms と、50〜100ms 短くなった
- **TTFB 全体では、効果は見えなかった。** 実行環境の起動時間のばらつきが、短縮した分より大きい
- バックグラウンドでの Secrets Manager の取得は 200〜260ms かかり、リクエスト内で取得していたとき（83〜104ms）の 2 倍以上だった。Next.js の初期化と CPU を取り合っているためと考えられる
- リクエストはパスワードの取得が終わる約 60ms 前に届くので、結局、完了を待つことになる

つまり、**アプリ側の工夫で縮められるのは、全体の 1 割程度（数十〜100ms）が限度だった。** 次の候補は、(a) `lambda/index.js` の先頭で取得を始める（CPU の取り合いと、公式の推奨に反する点が懸念）、(b) Valkey の IAM 認証にして取得そのものをなくす、(c) Secrets Manager を VPC エンドポイント経由にする（月約 10 USD / AZ）、(d) 定期アクセスで温めておく。いずれも未実施。

## 8. 費用

東京リージョンの月額の概算（設計時の見積もり。実績は未確認。検証は 1 日で撤去し、費用は発生していない）。

| 項目 | 目安 |
| --- | --- |
| NAT Gateway（1 台） | 約 45 USD ＋ 通信量 0.062 USD/GB |
| ElastiCache Serverless for Valkey | 6〜7 USD ＋ ECPU |
| EIP（NAT 用） | 約 3.6 USD |
| そのほか（Secrets Manager、CloudFront、Route 53、S3、ログ） | 数 USD |
| Lambda Web Functions | 従量課金。アイドル時はゼロ |
| **合計（アイドル時）** | **約 60 USD** |

- 固定費の大半は、VPC 内のリソースに届くための代償（Connector ＋ NAT）。外部通信を VPC エンドポイントに置き換えると、NAT をなくせる可能性があるが、呼び出し先が AWS サービスだけの場合に限る
- 料金ページに Connector 本体の料金の記載はない。VPC との間のデータ転送には、同一リージョンの転送料金がかかる

## 9. 運用・計測のノウハウ

- **計装は先に入れる。** `Server-Timing`（`total`、`valkey`、`external`）、JSON のアクセスログ、実行環境の ID、`coldStart`、`sinceReadyMs` があったので、クライアントの値とサーバーの値を突き合わせて、段階ごとの内訳が出せた
- ログの集計は CloudWatch Logs Insights（`scripts/insights.sh`）。計測時の UTC の時間帯を指定する
- 事前に `aws lambda-web get-web-account-settings` で、アカウントの秒間リクエスト数と Arm vCPU 数の上限を確認する
- 負荷試験で外部 API を叩かない（第三者の無償 API のため）。診断用のエンドポイントは、20 秒に 1 回だけ呼ぶ
- Server Action の ID はビルドごとに変わるので、k6 の `setup()` で画面とクライアント JS から取り出す
- 書き込みの負荷は、追加ではなく既存の TODO の完了切り替えにする（追加だと上限に数秒で達する）
- ボットのアクセスは、アイドル後の計測に混ざる。コールドスタートの回数が少ないときは、ログで実行環境を確認してから解釈する

## 10. 作業環境での落とし穴

| 事象 | 原因と対処 |
| --- | --- |
| zsh のループで `for path in ...` と書くと、以降のコマンドが見つからなくなる | zsh では `path` が `PATH` と連動している。別の変数名を使う |
| スクリプトで、全角文字の直前の変数展開が壊れる | `${...}` で囲む |
| GitHub Actions に `Detected a pnpm v10 installation layout at PNPM_HOME` の警告が出る | `pnpm/action-setup` の環境に起因する。動作には影響しない |
| GitHub Actions で `lambda-web` コマンドがない | ワークフローの中で、AWS CLI v2 を毎回最新版に更新している |

## 11. 本番に使うなら（検証から言えること）

### 向いている点

- フレームワークを選ばず、通常の HTTP サーバーをそのまま動かせる。Next.js を載せるためのアダプタや、実行環境用の改造がほぼ要らない
- 同時リクエストを 1 つの実行環境で処理できる（Event Functions と違い、1 リクエスト 1 実行環境ではない）ので、Valkey の接続を使い回しやすい
- アイドル時の従量課金がゼロ。ウォーム時の性能は十分で、50 rps の急増でもエラーがなかった

### 注意が必要な点

| 観点 | 内容 |
| --- | --- |
| コールドスタート | TTFB で 1.2〜1.9 秒。アプリで縮められるのは 1 割程度。常時低レイテンシが要るなら、定期アクセスで温めるか、別の基盤を考える |
| ネットワーク | 受信を閉域にできない。VPC 内のリソースに届くには、Connector が必要で、外部通信も含めるなら NAT Gateway が加わり、固定費の大半になる |
| IaC | Terraform で管理できない部分があり、2 段階の apply と、CI からの revision 作成が要る。プロバイダの対応で変わる可能性がある |
| 秘匿情報 | 基盤による注入がない。アプリで取得するなら、コールドスタートと NAT への依存が増える |
| デプロイ | カナリアは `Disabled` ＋ 重みで手動。メトリクスに revision の次元がない。切り替え中の混在の挙動は未確認 |
| 公開 | URL は常に公開される。CloudFront と WAF、`IamAuth` の併用を前提に考える |

## 12. 未確認・未決定の事項

| 項目 | 状態 |
| --- | --- |
| `LatestRevision` の切り替え中の新旧の混在、5xx、ドレイン | 未確認（[deploy-mixing.md](./deploy-mixing.md)） |
| ゼロまでスケールインする時間 | 不明（ボットのアクセスが混ざる） |
| Valkey の認証方式 | 未決定（[notes.md](./notes.md) 2 章） |
| コールドスタートの追加の改善（取得の開始を早める、IAM 認証、VPC エンドポイント） | 未実施 |
| スケールアウトの観察（実行環境あたりの最大同時リクエスト数を下げる） | 未実施 |
| 負荷試験の合格基準 | 未決定 |
| Secrets の直接注入、レイヤー・拡張への対応 | 未確認 |
| `aws:SourceIp` で `IamAuth` のエンドポイントを絞れるか | 未検証 |
| 実際の費用 | 未確認（見積もりのみ） |
