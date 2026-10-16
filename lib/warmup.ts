import { errorFields, logger } from "./logger";
import { getValkey } from "./valkey";

/**
 * 最初のリクエストで発生する初期化（Secrets Manager からのパスワード取得と、Valkey への接続）を、
 * リクエストを待たずに始めておく。
 *
 * getValkey() は作成中のクライアントの Promise を globalThis に保持するので、
 * 完了前に届いたリクエストは同じ Promise を待つ（接続を二重に作らない）。
 * 失敗しても起動は止めない。Secrets Manager の取得に失敗した場合は、getValkey() が失敗した Promise を捨てるので、
 * 次のリクエストで取得し直す。Valkey に届かない場合は、クライアント（iovalkey）が裏で再接続を続ける。
 */
export async function warmUp(): Promise<void> {
  const start = performance.now();
  try {
    const client = await getValkey();
    // 接続を確立させるため、コマンドを 1 つ送る
    await client.ping();
    logger.info("warmup completed", { durationMs: Number((performance.now() - start).toFixed(1)) });
  } catch (error) {
    logger.warn("warmup failed", {
      durationMs: Number((performance.now() - start).toFixed(1)),
      ...errorFields(error),
    });
  }
}
