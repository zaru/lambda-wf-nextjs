// Lambda Web Functions 用のエントリポイント。
// scripts/package.sh が Next.js の standalone 出力の直下にコピーする。
//
// 1. Web Functions が渡す AWS_LAMBDA_HTTP_ENDPOINT（host:port）を、
//    standalone の server.js が読む HOSTNAME と PORT に変換する
// 2. 計測のため、HTTP サーバーにアクセスログ、Server-Timing ヘッダ、
//    リクエストごとのコンテキスト（AsyncLocalStorage）を差し込む
const http = require("node:http");
const { AsyncLocalStorage } = require("node:async_hooks");
const { performance } = require("node:perf_hooks");

const address = process.env.AWS_LAMBDA_HTTP_ENDPOINT ?? "0.0.0.0:3000";
const sep = address.lastIndexOf(":");
process.env.HOSTNAME = address.slice(0, sep);
process.env.PORT = address.slice(sep + 1);

// アプリ側（lib/request-context.ts）からも同じインスタンスを参照できるよう、globalThis に置く
const requestContext = new AsyncLocalStorage();
globalThis.__wfRequestContext = requestContext;

const environmentId = Math.random().toString(36).slice(2, 10);
let requestCount = 0;

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
      requestCount,
    });
  });

  return requestContext.run(ctx, () => originalEmit.call(this, event, req, res, ...rest));
};

const originalListen = http.Server.prototype.listen;
http.Server.prototype.listen = function listen(...args) {
  this.once("listening", () => {
    // プロセスの起動から待ち受け開始までの時間（コールドスタートのうち、アプリの初期化分）
    log({ type: "ready", uptimeMs: Number((process.uptime() * 1000).toFixed(1)) });
  });
  return originalListen.apply(this, args);
};

log({ type: "init", nodeVersion: process.version });

require("./server.js");
