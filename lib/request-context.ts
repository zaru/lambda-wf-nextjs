import type { AsyncLocalStorage } from "node:async_hooks";

type RequestContext = {
  start: number;
  coldStart: boolean;
  timings: Record<string, number>;
};

declare global {
  // lambda/index.js が設定する。next dev では未定義
  var __wfRequestContext: AsyncLocalStorage<RequestContext> | undefined;
}

/**
 * 処理にかかった時間を、リクエストのコンテキストに積算する。
 * 積算した値は Server-Timing ヘッダとアクセスログに出る（lambda/index.js）
 */
export async function measure<T>(name: string, fn: () => Promise<T>): Promise<T> {
  const start = performance.now();
  try {
    return await fn();
  } finally {
    const ctx = globalThis.__wfRequestContext?.getStore();
    if (ctx) {
      ctx.timings[name] = (ctx.timings[name] ?? 0) + (performance.now() - start);
    }
  }
}
