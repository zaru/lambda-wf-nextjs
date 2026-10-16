// Lambda Web Functions 用のエントリポイント。
// scripts/package.sh が Next.js の standalone 出力の直下にコピーする。
//
// このファイルは 2 つの役割が混ざっている。
//
// 【必須】 Web Functions が渡す AWS_LAMBDA_HTTP_ENDPOINT（host:port）を、
//          standalone の server.js が読む HOSTNAME と PORT に変換する
//          （「必須部分」の節と、末尾の require("./server.js")）。
//          これが無いと server.js が Lambda の指定と違うポートで待ち受け、リクエストが届かない
// 【計測】 レイテンシや負荷試験の計測のため、HTTP サーバーにアクセスログ、
//          Server-Timing ヘッダ、リクエストごとのコンテキスト（AsyncLocalStorage）を差し込む
//          （「計測用の部分」の節）。動作には不要で、本番では削除や分離ができる。
//          ただし lib/request-context.ts が globalThis.__wfRequestContext を参照する
const http = require("node:http");
const { AsyncLocalStorage } = require("node:async_hooks");
const { performance } = require("node:perf_hooks");

// ============================================================
// 必須部分: Lambda のエンドポイントを server.js 用の環境変数に変換する
// ============================================================
const address = process.env.AWS_LAMBDA_HTTP_ENDPOINT ?? "0.0.0.0:3000";
const sep = address.lastIndexOf(":");
process.env.HOSTNAME = address.slice(0, sep);
process.env.PORT = address.slice(sep + 1);

// ============================================================
// 計測用の部分: ここから require("./server.js") の直前までは、動作に不要
// ============================================================

// アプリ側（lib/request-context.ts）からも同じインスタンスを参照できるよう、globalThis に置く
const requestContext = new AsyncLocalStorage();
globalThis.__wfRequestContext = requestContext;

const environmentId = Math.random().toString(36).slice(2, 10);
let requestCount = 0;
// 待ち受けを始めた時刻。最初のリクエストが届くまでの時間を測るのに使う
let readyAt;

function log(fields) {
  process.stdout.write(
    `${JSON.stringify({ time: new Date().toISOString(), environmentId, ...fields })}\n`,
  );
}

function serverTimingHeader(ctx) {
  const entries = [`total;dur=${(performance.now() - ctx.start).toFixed(1)}`];
  for (const [name, dur] of Object.entries(ctx.timings)) {
    entries.push(`${name};dur=${dur.toFixed(1)}`);
  }
  return entries.join(", ");
}

const originalEmit = http.Server.prototype.emit;
http.Server.prototype.emit = function emit(event, req, res, ...rest) {
  if (event !== "request") {
    return originalEmit.call(this, event, req, res, ...rest);
  }

  requestCount += 1;
  const ctx = {
    start: performance.now(),
    coldStart: requestCount === 1,
    timings: {},
  };
  // 最初のリクエストについて、待ち受けを始めてから届くまでの時間を記録する。
  // 数百 ms 程度なら、このリクエストが実行環境の起動を待っていた（利用者がコールドスタートを体験した）。
  // 数秒以上なら、需要に先回りして用意された実行環境に、あとからリクエストが来た（起動は待っていない）
  const sinceReadyMs =
    ctx.coldStart && readyAt !== undefined ? Number((ctx.start - readyAt).toFixed(1)) : undefined;

  // ヘッダが送られる直前に Server-Timing を付ける。
  // ストリーミングの場合は、その時点までの所要時間になる
  const originalWriteHead = res.writeHead;
  res.writeHead = function writeHead(...args) {
    if (!res.headersSent) {
      res.setHeader("Server-Timing", serverTimingHeader(ctx));
    }
    return originalWriteHead.apply(this, args);
  };

  res.once("finish", () => {
    log({
      type: "access",
      method: req.method,
      path: req.url,
      status: res.statusCode,
      durationMs: Number((performance.now() - ctx.start).toFixed(1)),
      timings: Object.fromEntries(
        Object.entries(ctx.timings).map(([name, dur]) => [name, Number(dur.toFixed(1))]),
      ),
      coldStart: ctx.coldStart,
      sinceReadyMs,
      requestCount,
    });
  });

  return requestContext.run(ctx, () => originalEmit.call(this, event, req, res, ...rest));
};

const originalListen = http.Server.prototype.listen;
http.Server.prototype.listen = function listen(...args) {
  this.once("listening", () => {
    readyAt = performance.now();
    // プロセスの起動から待ち受け開始までの時間（コールドスタートのうち、アプリの初期化分）
    log({ type: "ready", uptimeMs: Number((process.uptime() * 1000).toFixed(1)) });
  });
  return originalListen.apply(this, args);
};

log({ type: "init", nodeVersion: process.version });

// ============================================================
// 必須部分: 環境変数を設定したあとで、Next.js の standalone サーバーを起動する
// ============================================================
require("./server.js");
