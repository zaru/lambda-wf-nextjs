import { errorFields, logger } from "@/lib/logger";
import { withValkey } from "@/lib/valkey";

export const dynamic = "force-dynamic";

export async function GET() {
  const start = performance.now();
  try {
    const reply = await withValkey((client) => client.ping());
    return Response.json({
      status: "ok",
      valkey: { ok: reply === "PONG", latencyMs: Number((performance.now() - start).toFixed(1)) },
    });
  } catch (error) {
    logger.error("health check failed", errorFields(error));
    return Response.json({ status: "error", valkey: { ok: false } }, { status: 503 });
  }
}
