import { z } from "zod";

const booleanString = z
  .enum(["true", "false"])
  .default("false")
  .transform((value) => value === "true");

const schema = z.object({
  VALKEY_HOST: z.string().min(1),
  VALKEY_PORT: z.coerce.number().int().positive().default(6379),
  VALKEY_TLS: booleanString,
  VALKEY_CLUSTER_MODE: booleanString,
  VALKEY_USERNAME: z.string().min(1).optional(),
  VALKEY_SECRET_ARN: z.string().min(1).optional(),
  HOLIDAY_API_URL: z.url().default("https://holidays-jp.github.io/api/v1/date.json"),
});

export type Config = z.infer<typeof schema>;

let cached: Config | undefined;

/**
 * 環境変数を読み込んで検証する。ビルド時に評価されないよう、最初に使うときに読む
 */
export function getConfig(): Config {
  cached ??= schema.parse(process.env);
  return cached;
}
