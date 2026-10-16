# Web Functions のデプロイ中に、新旧の revision が混ざるか

調査日: 2026-10-16

## 1. 結論

**混ざる可能性はある。** ただし、切り替えの瞬間に旧 revision が処理中のリクエストをどう扱うか（ドレインの挙動）は、公式ドキュメントに記載がない。未確認の事項として扱う。

## 2. ドキュメントで確認できたこと

出典: https://docs.aws.amazon.com/lambda/latest/dg/web-functions-deployment.html

| 項目 | 内容 |
|---|---|
| `LatestRevision` | 新しい revision が Active になると、エンドポイントの 100% のトラフィックをそちらへ切り替える。このリポジトリの現在のモード |
| `Disabled` | 新しい revision を作ってもトラフィックは動かない。revision weights で手動制御する（カナリア、ブルーグリーン用） |
| revision weights | 1〜100 の整数で、合計は 100。同時に指定できるのは最大 2 revision。Active の revision だけ指定できる |
| 更新の方式 | モードと重みの変更は、非同期のエンドポイント更新。`updateStatus` が `Successful` になるまで待つ必要がある |
| モードの切り替え | `LatestRevision` → `Disabled` は現在の割り当てを維持する。`Disabled` → `LatestRevision` は、最新の revision（Active である必要がある）に 100% 向ける |
| revision の削除 | トラフィックを受けている revision は削除できない（競合エラー） |
| メトリクス | Web Function のメトリクスには revision の次元がない。カナリアのエラーを切り分けるには、アプリのログやカスタムメトリクスにビルド ID を入れる |

## 3. 混在が起きる場面

| 場面 | 新旧が混ざるか |
|---|---|
| `LatestRevision` の切り替え中 | 切り替えが原子的だという記述はない。非同期更新の前後で、新旧どちらにもリクエストが届き得る（実測は未実施） |
| カナリア（`Disabled` ＋重み） | 意図的に混ぜる。重みの比率で配分される |

## 4. 混在で実害が出やすい箇所

- **同じ画面の中で混ざる**: 旧 revision で HTML を受け取ったブラウザが、続くリクエスト（`_next/static` のチャンク、API、Server Actions）を新 revision に送ることがある。Next.js はビルドごとにアセットのハッシュや Server Action の ID が変わるため、404 や ID の不一致になり得る
- **Valkey のセッションやデータ構造**: 新旧のコードが同じ Valkey を読み書きする。形式を変えるときは、新旧の両方が読める状態を挟む二段階のデプロイにする

## 5. 対策の候補

1. セッションやキャッシュの形式は、後方互換を保つ（読めるようにしてから、書く形式を変える）
2. 旧ビルドの `_next/static` を、一定期間 CloudFront 側（S3 など）に残す
3. `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` を固定し、ビルド間で Server Actions の暗号化キーを揃える
4. ログにビルド ID を入れ、revision ごとの挙動を切り分けられるようにする

これらはドキュメントの記述と Next.js 一般の知識に基づく案で、このリポジトリでは未実装・未検証。

## 6. 未確認の事項

- `LatestRevision` の切り替え中に、新旧が混ざる時間の長さと、5xx の有無
- 旧 revision の処理中リクエストが、切り替え時に完了まで待たれるか

確認する場合は、`LatestRevision` でデプロイしながら k6 で負荷をかけ、レスポンスにビルド ID を入れて、新旧の比率と 5xx を時系列で見る。
