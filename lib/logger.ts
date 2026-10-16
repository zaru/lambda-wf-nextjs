type Level = "debug" | "info" | "warn" | "error";

// console.log を使うと、Lambda のランタイムが出力を {"timestamp", "level", "message": "<元の文字列>"} に包み、
// JSON の各項目を CloudWatch Logs Insights で検索できなくなる。
// lambda/index.js のアクセスログと同じく、標準出力に JSON をそのまま書く
function write(level: Level, message: string, fields?: Record<string, unknown>) {
  const line = JSON.stringify({ time: new Date().toISOString(), level, message, ...fields });
  const stream = level === "error" || level === "warn" ? process.stderr : process.stdout;
  stream.write(`${line}\n`);
}

export const logger = {
  debug: (message: string, fields?: Record<string, unknown>) => write("debug", message, fields),
  info: (message: string, fields?: Record<string, unknown>) => write("info", message, fields),
  warn: (message: string, fields?: Record<string, unknown>) => write("warn", message, fields),
  error: (message: string, fields?: Record<string, unknown>) => write("error", message, fields),
};

export function errorFields(error: unknown): Record<string, unknown> {
  if (error instanceof Error) {
    return { errorName: error.name, errorMessage: error.message };
  }
  return { errorMessage: String(error) };
}
