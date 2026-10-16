import Redis, { Cluster } from "iovalkey";
import { getConfig } from "./config";
import { errorFields, logger } from "./logger";
import { measure } from "./request-context";
import { getSecretString } from "./secrets";

export type ValkeyClient = Redis | Cluster;

const CONNECT_TIMEOUT_MS = 5_000;
const COMMAND_TIMEOUT_MS = 3_000;

declare global {
  // 実行環境ごとに 1 つのクライアントを使い回す（開発時のホットリロードでも増やさない）
  var __valkeyClient: Promise<ValkeyClient> | undefined;
}

async function createClient(): Promise<ValkeyClient> {
  const config = getConfig();
  const password = config.VALKEY_SECRET_ARN
    ? await getSecretString(config.VALKEY_SECRET_ARN)
    : undefined;

  const commonOptions = {
    username: config.VALKEY_USERNAME,
    password,
    connectTimeout: CONNECT_TIMEOUT_MS,
    commandTimeout: COMMAND_TIMEOUT_MS,
    tls: config.VALKEY_TLS ? {} : undefined,
  };

  const client: ValkeyClient = config.VALKEY_CLUSTER_MODE
    ? new Cluster([{ host: config.VALKEY_HOST, port: config.VALKEY_PORT }], {
        // ElastiCache Serverless は TLS 必須。ノードのアドレスを IP に解決すると
        // 証明書のホスト名と一致しなくなるため、ホスト名のまま接続する
        dnsLookup: (address, callback) => callback(null, address),
        redisOptions: commonOptions,
        slotsRefreshTimeout: CONNECT_TIMEOUT_MS,
      })
    : new Redis({ host: config.VALKEY_HOST, port: config.VALKEY_PORT, ...commonOptions });

  client.on("error", (error) => {
    logger.error("valkey client error", errorFields(error));
  });

  return client;
}

/**
 * Valkey クライアントを返す。初回は Secrets Manager からパスワードを取得して接続する
 */
export function getValkey(): Promise<ValkeyClient> {
  if (!globalThis.__valkeyClient) {
    globalThis.__valkeyClient = createClient().catch((error) => {
      // 失敗したら次のリクエストで作り直せるよう、キャッシュを捨てる
      globalThis.__valkeyClient = undefined;
      throw error;
    });
  }
  return globalThis.__valkeyClient;
}

/**
 * Valkey へのコマンドを実行し、所要時間を Server-Timing に積算する
 */
export async function withValkey<T>(fn: (client: ValkeyClient) => Promise<T>): Promise<T> {
  const client = await measure("valkeyConnect", getValkey);
  return measure("valkey", () => fn(client));
}
