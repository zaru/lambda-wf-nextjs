import { getHolidays } from "@/lib/holiday-client";
import { listTodos } from "@/lib/todo-repository";
import { type Filter, TodoApp } from "./_components/todo-app";

// Web Function は複数の実行環境にスケールし、Next.js のキャッシュは環境ごとに独立する。
// 環境間で表示がずれないよう、毎回 Valkey から読む
export const dynamic = "force-dynamic";

const FILTERS: readonly Filter[] = ["all", "active", "completed"];

function parseFilter(value: string | string[] | undefined): Filter {
  return FILTERS.find((filter) => filter === value) ?? "all";
}

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const [{ filter }, todos, holidays] = await Promise.all([
    searchParams,
    listTodos(),
    getHolidays(),
  ]);

  return (
    <main className="container">
      <h1>
        TODO Demo <span className="badge">検証用</span>
      </h1>
      <p className="notice">
        Lambda Web Functions
        の検証用アプリです。誰でも閲覧・編集できるため、個人情報は入力しないでください。
      </p>
      <TodoApp todos={todos} holidays={holidays} filter={parseFilter(filter)} />
    </main>
  );
}
