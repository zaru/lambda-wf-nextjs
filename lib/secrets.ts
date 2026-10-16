import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { measure } from "./request-context";

/**
 * Secrets Manager から文字列のシークレットを取得する。
 * 経路は Network Connector → NAT Gateway になる
 */
export async function getSecretString(secretId: string): Promise<string> {
  const client = new SecretsManagerClient({});
  const output = await measure("secrets", () =>
    client.send(new GetSecretValueCommand({ SecretId: secretId })),
  );
  if (!output.SecretString) {
    throw new Error(`Secret ${secretId} has no SecretString`);
  }
  return output.SecretString;
}
