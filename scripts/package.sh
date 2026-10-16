#!/usr/bin/env bash
# Next.js の standalone 出力を、Lambda Web Functions にデプロイできる zip にまとめる。
# 出力: dist/app.zip（zip のルートに index.js と server.js が来る）
set -euo pipefail

cd "$(dirname "$0")/.."

STANDALONE=.next/standalone

pnpm build

# standalone 出力には静的ファイルが含まれないので、コピーする
cp -R public "$STANDALONE/public"
mkdir -p "$STANDALONE/.next"
cp -R .next/static "$STANDALONE/.next/static"

# Web Functions 用のエントリポイント（ランタイムは既定でルートの index.js を読む）
cp lambda/index.js "$STANDALONE/index.js"

rm -rf dist
mkdir -p dist
(cd "$STANDALONE" && zip -qr ../../dist/app.zip . -x '*.DS_Store')

echo "created dist/app.zip ($(du -h dist/app.zip | cut -f1))"
echo "unzipped size: $(du -sh "$STANDALONE" | cut -f1)"
