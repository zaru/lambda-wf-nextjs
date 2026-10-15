# Lambda Web Functions のネットワーク構成の選択肢

- 作成日: 2026-10-16
- ステータス: 検討中（VPC 構成を採るかどうかは未決定）
- 関連: [設計書](./design.md)

Lambda Web Functions（2026-10-12 GA）を採用する場合のネットワーク構成について、調査で分かったことと選択肢を整理する。

## 1. Web Functions のネットワークモデル（前提）

調査で分かった前提は次のとおり。

- Web Function 本体には Subnet や VPC の設定項目がない。常に Lambda が管理する基盤で動き、VPC の中には置けない
- **受信**は常に、Lambda が管理する公開 HTTPS エンドポイントから入る。PrivateLink には対応していない
  - 認証タイプは `ApplicationManaged`（アプリ側で認証）と `IamAuth`（SigV4 署名が必要）から選ぶ。どちらでもネットワークとしては公開のまま
- **送信**は revision ごとに次のどちらかを選ぶ
  - Connector なし: パブリック IPv4 の宛先に直接出る。送信元 IP は固定されず、VPC 内のリソースには届かない
  - Network Connector あり: **すべての**外向き通信が Connector の ENI を通って VPC に入る。インターネットに出るには NAT Gateway などが必要
- Network Connector を使えるのは `HomeRegion` エンドポイントだけ（マルチリージョンでは使えない）
- 料金ページに Connector 本体の料金の記載はない。Web Functions と VPC の間のデータ転送には、同一リージョン内のデータ転送料金がかかる

```mermaid
flowchart LR
    Client["クライアント<br/>ブラウザ / 社内システム"]

    subgraph Lambda["Lambda 管理基盤（VPC の外）"]
        EP["Web Function エンドポイント<br/>常に公開・HTTPS<br/>ApplicationManaged / IamAuth"]
        Rev["Web Function revision<br/>実行環境"]
        EP --> Rev
    end

    subgraph VPC["自分の VPC"]
        ENI["Network Connector の ENI<br/>Private Subnet × 2 AZ 以上"]
        Private["VPC 内リソース<br/>RDS / ElastiCache / 社内 API"]
        NAT["NAT Gateway"]
        ENI --> Private
        ENI -.->|インターネットに出る場合| NAT
    end

    Internet["インターネット<br/>外部 API / AWS API"]

    Client -->|受信は常に公開経路| EP
    Rev -->|"Connector なし<br/>送信元 IP は固定されない"| Internet
    Rev -->|"Connector あり<br/>外向き通信がすべて VPC 経由"| ENI
    NAT --> Internet
```

## 2. データストアへの接続方式

### 2.1 判断フロー

```mermaid
flowchart TD
    Start(["データストアに接続したい"]) --> Q1{"データストアは<br/>VPC 内からしか届かない？"}

    Q1 -->|"はい<br/>RDS / ElastiCache の通常構成"| NeedConn["Network Connector が必須"]
    Q1 -->|"いいえ"| NoVPC["Connector 不要<br/>VPC 自体が不要になる"]

    NoVPC --> PubOpt["公開エンドポイント ＋ IAM 認証<br/>・ElastiCache Serverless（Valkey 9 以上）<br/>・Aurora の RDS Data API<br/>・Aurora DSQL<br/>・DynamoDB"]
    PubOpt --> OptC["案 C"]

    NeedConn --> Q2{"外部 API や AWS API を<br/>呼ぶ必要がある？"}
    Q2 -->|"いいえ<br/>DB だけに接続する"| OptA["案 A<br/>Connector のみ・NAT なし"]
    Q2 -->|"はい"| Q3{"送信元 IP の固定や<br/>外向き通信の検査が必要？"}

    Q3 -->|"はい"| OptB_NAT["案 B<br/>Connector ＋ NAT Gateway"]
    Q3 -->|"いいえ"| Q4{"呼び出し先は<br/>AWS サービスだけ？"}
    Q4 -->|"はい"| OptB_VPCE["案 B'<br/>Connector ＋ VPC エンドポイント"]
    Q4 -->|"いいえ<br/>外部 SaaS なども呼ぶ"| OptB_NAT

    NG["パブリックアクセス可の RDS を<br/>SG で開放する"]:::ng
    Q1 -.->|"非推奨<br/>送信元 IP が不定で SG で絞れない"| NG

    classDef ng fill:#fdd,stroke:#c00,color:#900
```

### 2.2 案 A: Connector のみ（NAT なし）

```mermaid
flowchart LR
    Browser["ブラウザ"] --> EP["Web Function<br/>エンドポイント"]
    EP --> Rev["revision"]

    subgraph VPC["VPC（IGW / NAT なし）"]
        subgraph PS["Private Subnet × 2"]
            ENI["Connector ENI"]
            Cache[("ElastiCache<br/>Serverless Valkey")]
        end
        ENI -->|"TLS 6379"| Cache
    end

    Rev --> ENI
    Rev -.-x|"外部 API / AWS API には届かない"| X["インターネット"]
```

### 2.3 案 B: Connector ＋ NAT Gateway または VPC エンドポイント

```mermaid
flowchart LR
    Browser["ブラウザ"] --> EP["Web Function<br/>エンドポイント"]
    EP --> Rev["revision"]

    subgraph VPC["VPC"]
        subgraph PS["Private Subnet × 2"]
            ENI["Connector ENI"]
            Cache[("ElastiCache<br/>Serverless Valkey")]
            VPCE["VPC エンドポイント<br/>Secrets Manager など"]
        end
        subgraph PubS["Public Subnet"]
            NAT["NAT Gateway<br/>EIP で送信元 IP を固定"]
        end
        IGW["Internet Gateway"]
        ENI --> Cache
        ENI -->|"案 B'"| VPCE
        ENI -->|"案 B"| NAT
        NAT --> IGW
    end

    Rev --> ENI
    IGW --> Ext["外部 API / SaaS"]
```

### 2.4 案 C: VPC なし（公開エンドポイント ＋ IAM 認証）

```mermaid
flowchart LR
    Browser["ブラウザ"] --> EP["Web Function<br/>エンドポイント"]
    EP --> Rev["revision<br/>Connector なし"]
    Rev -->|"TLS ＋ IAM 認証トークン<br/>有効期限 15 分・定期的に更新"| Cache[("ElastiCache Serverless<br/>公開エンドポイント<br/>Valkey 9 以上")]
    Rev --> Ext["外部 API / AWS API<br/>直接呼べる"]
```

### 2.5 比較

| 観点 | 案 A: Connector のみ | 案 B: Connector ＋ NAT | 案 B': Connector ＋ VPC エンドポイント | 案 C: VPC なし |
| --- | --- | --- | --- | --- |
| データストアの露出 | VPC 内に閉じる | VPC 内に閉じる | VPC 内に閉じる | インターネットから届く（IAM で保護する） |
| 外部 API の呼び出し | できない | できる | AWS サービスだけ | できる |
| 送信元 IP の固定 | 対象外 | できる（EIP） | 対象外 | できない |
| 外向き通信の検査 | 対象外 | できる（Network Firewall など） | 限定的 | できない |
| 月額の固定費（東京・概算） | Valkey のみ | ＋ NAT 約 45 USD × AZ 数 ＋ 通信量 | ＋ 約 10 USD × エンドポイント数 × AZ 数 | Valkey のみ |
| 構成の複雑さ | 中 | 高 | 中〜高 | 低 |
| アプリの実装 | 標準的 | 標準的 | 標準的 | IAM トークンの更新処理が必要 |
| マルチリージョン | 使えない | 使えない | 使えない | 使える |
| 向いている場面 | デモ、DB だけに接続するアプリ | 規程・監査で求められる本番 | AWS サービスとだけ連携する本番 | インフラを持たない利点を最大化したい場合 |

## 3. 社内向けの内部用 API の構成

Web Functions は受信を Private にできない。社内システムから呼ぶ API の場合、「ネットワークで閉じる必要があるか」で構成が分かれる。

### 3.1 判断フロー

```mermaid
flowchart TD
    Start(["社内システムから呼ぶ<br/>内部用 API を作りたい"]) --> Q1{"インターネットから届かないことが<br/>規程や監査の要件？"}

    Q1 -->|"いいえ<br/>認証による保護で足りる"| WF["Web Functions ＋ IamAuth<br/>・呼び出し側は SigV4 で署名<br/>・リソースポリシーでプリンシパルを限定"]
    Q1 -->|"はい<br/>ネットワークで閉じる必要がある"| Q2{"サーバーレスを<br/>維持したい？"}

    Q2 -->|"はい"| Q3{"パスでのルーティングなど<br/>柔軟なルーティングが必要？"}
    Q3 -->|"いいえ"| PAPI["Event Functions ＋<br/>Private API Gateway（REST）"]
    Q3 -->|"はい"| IALB["Event Functions ＋ 内部 ALB"]
    Q2 -->|"いいえ"| ECS["ECS ＋ 内部 ALB"]

    WF -.- Note1["注意<br/>・URL 自体はインターネットから届く<br/>・aws:SourceVpc では絞れない<br/>・aws:SourceIp で絞れるかは未検証<br/>・呼び出し側の VPC に出口が必要"]:::note

    classDef note fill:#ffd,stroke:#aa0,color:#550
```

### 3.2 構成

```mermaid
flowchart LR
    subgraph Caller["社内システムの VPC"]
        App["社内システム"]
        NAT["NAT Gateway"]
        VPCE["execute-api の<br/>VPC エンドポイント"]
        ALB["内部 ALB"]
    end

    subgraph Opt1["Web Functions ＋ IamAuth"]
        EP["Web Function<br/>エンドポイント（公開）"]
    end

    subgraph Opt2["Event Functions ＋ Private API Gateway"]
        APIGW["Private REST API"]
        EF1["Event Function"]
        APIGW --> EF1
    end

    subgraph Opt3["Event Functions / ECS ＋ 内部 ALB"]
        EF2["Event Function<br/>または ECS タスク"]
    end

    App -->|"SigV4 署名"| NAT
    NAT -->|"公開経路"| EP
    App -->|"閉じた経路"| VPCE
    VPCE --> APIGW
    App -->|"閉じた経路"| ALB
    ALB --> EF2
```

### 3.3 比較

| 観点 | Web Functions ＋ IamAuth | Event Functions ＋ Private API Gateway | Event Functions ＋ 内部 ALB | ECS ＋ 内部 ALB |
| --- | --- | --- | --- | --- |
| 受信経路 | 公開（認証で保護する） | 閉じている | 閉じている | 閉じている |
| VPC や VPC エンドポイントで制限 | できない | できる（リソースポリシー） | SG で制限する | SG で制限する |
| 呼び出し側の実装 | SigV4 署名が必須 | 通常の HTTP（IAM 認証にもできる） | 通常の HTTP | 通常の HTTP |
| 固定費（概算） | ほぼなし（呼び出し側に NAT がなければ必要） | VPC エンドポイント約 10 USD × AZ 数 | ALB 約 20 USD〜 | ALB ＋ タスク ＋ NAT |
| フレームワークの扱い | Express や Next.js をそのまま動かせる | Event Functions 用のハンドラかアダプタが必要 | 同左 | そのまま動かせる |

## 4. 今回の TODO アプリでの扱い

- 決定事項: リージョンは東京、外部から誰でもアクセスできる → 受信は Web Functions の公開エンドポイントで問題ない
- 未決定: データストアへの接続方式（2 章の案 A / B / C）
  - 判断材料: 想定する本番で、送信元 IP の固定が必要か、外向き通信の検査や閉域が規程で求められるか、データストアをインターネットから届く場所に置いてよいか
  - 検証案: 案 A を土台に作り、NAT を Terraform の変数で後から足せる形にして、疎通、コールドスタート、費用を実測で比べる。案 C を比較対象に加えるかどうかは、上の判断材料の答え次第
- 内部用 API（3 章）を今回の検証範囲に入れるかどうかは未定

## 参考

- [Configuring networking for AWS Lambda Web Functions](https://docs.aws.amazon.com/lambda/latest/dg/web-functions-networking.html)
- [Lambda Web Function endpoint access control](https://docs.aws.amazon.com/lambda/latest/dg/web-functions-endpoint-access-control.html)
- [CreateNetworkConnector API](https://docs.aws.amazon.com/lambda/latest/lambda-core/API_CreateNetworkConnector.html)
- [AWS Lambda Pricing](https://aws.amazon.com/lambda/pricing/)
- [Amazon ElastiCache FAQs](https://aws.amazon.com/elasticache/faqs/)
