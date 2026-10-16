import { fetchHolidays } from "@/lib/holiday-client";
import { errorFields, logger } from "@/lib/logger";

// NAT Gateway 経由の外部通信のレイテンシを測るための API。
// 第三者が無償で提供している API を呼ぶので、負荷試験には使わず、低頻度の計測に限ること
export const dynamic = "force-dynamic";

export async function GET() {
  const start = performance.now();
  try {
    const holidays = await fetchHolidays();
    return Response.json({
      status: "ok",
      latencyMs: Number((performance.now() - start).toFixed(1)),
      holidayCount: Object.keys(holidays).length,
    });
  } catch (error) {
    logger.error("external diag failed", errorFields(error));
    return Response.json(
      { status: "error", latencyMs: Number((performance.now() - start).toFixed(1)) },
      { status: 502 },
    );
  }
}
