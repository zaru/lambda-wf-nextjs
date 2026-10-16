import { z } from "zod";
import { getConfig } from "./config";
import { errorFields, logger } from "./logger";
import { measure } from "./request-context";
import { withValkey } from "./valkey";

const CACHE_KEY = "{todo}:holidays";
const LOCK_KEY = "{todo}:holidays:lock";
const CACHE_TTL_SECONDS = 24 * 60 * 60;
const LOCK_TTL_SECONDS = 10;
const FETCH_TIMEOUT_MS = 3_000;

// { "2026-11-03": "文化の日", ... }
const holidaysSchema = z.record(z.string(), z.string());
export type Holidays = z.infer<typeof holidaysSchema>;

/**
 * 祝日 API をキャッシュなしで呼ぶ。経路は Network Connector → NAT Gateway になる
 */
export async function fetchHolidays(): Promise<Holidays> {
  const { HOLIDAY_API_URL } = getConfig();
  return measure("external", async () => {
    const response = await fetch(HOLIDAY_API_URL, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`Holiday API responded ${response.status}`);
    }
    return holidaysSchema.parse(await response.json());
  });
}

/**
 * 祝日データを返す。Valkey に 24 時間キャッシュする。
 * 取得に失敗しても画面の表示は止めず、空のデータを返す
 */
export async function getHolidays(): Promise<Holidays> {
  try {
    const cached = await withValkey((client) => client.get(CACHE_KEY));
    if (cached) {
      return holidaysSchema.parse(JSON.parse(cached));
    }

    // 複数のリクエストが同時に外部 API を呼ばないよう、ロックを取れたリクエストだけが取得する
    const locked = await withValkey((client) =>
      client.set(LOCK_KEY, "1", "EX", LOCK_TTL_SECONDS, "NX"),
    );
    if (locked !== "OK") {
      return {};
    }

    const holidays = await fetchHolidays();
    await withValkey((client) =>
      client.set(CACHE_KEY, JSON.stringify(holidays), "EX", CACHE_TTL_SECONDS),
    );
    return holidays;
  } catch (error) {
    logger.warn("failed to get holidays", errorFields(error));
    return {};
  }
}
