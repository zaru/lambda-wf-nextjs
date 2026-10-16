// Next.js がサーバーの起動時に 1 回だけ呼ぶフック。
// standalone の server.js では、待ち受けを始めた後に呼ばれ、
// register() が終わるまでリクエストの処理は待たされる。
export async function register() {
  if (process.env.NEXT_RUNTIME !== "nodejs") {
    return;
  }
  const { warmUp } = await import("./lib/warmup");
  // 完了は待たない。待つと Next.js の準備（ルートの読み込みなど）も、接続が終わるまで遅れる。
  // 接続の完了前に届いたリクエストは、lib/valkey.ts の getValkey() で同じ接続を待つ
  void warmUp();
}
