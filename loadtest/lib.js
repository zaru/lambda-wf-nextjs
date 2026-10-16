// k6 シナリオの共通処理

import { check } from "k6";
import http from "k6/http";

export const BASE_URL = __ENV.BASE_URL || "https://wf.dev.id.basicinc.jp";

// 負荷試験の前に用意しておく TODO の件数（書き込みはこれらの完了状態を切り替える）
const SEED_TODOS = Number(__ENV.SEED_TODOS || 30);

/**
 * 画面とクライアント JS を取得し、Server Action の ID（ビルドごとに変わる）と静的ファイルの URL を集める
 */
export function discover() {
  const page = http.get(`${BASE_URL}/`, { tags: { name: "setup" } });
  check(page, { "setup: page 200": (r) => r.status === 200 });

  const scripts = [...page.body.matchAll(/src="(\/_next\/static\/[^"]+\.js)"/g)].map((m) => m[1]);
  const actions = {};
  for (const src of scripts) {
    const body = http.get(`${BASE_URL}${src}`, { tags: { name: "setup" } }).body || "";
    for (const m of body.matchAll(/createServerReference\)\("([0-9a-f]+)"[^)]*?"(\w+Action)"\)/g)) {
      actions[m[2]] = m[1];
    }
  }
  if (!actions.toggleTodoAction || !actions.addTodoAction) {
    throw new Error(`Server Action の ID が見つかりません: ${JSON.stringify(actions)}`);
  }
  return { actions, staticAsset: scripts[0] };
}

export function callAction(actionId, args, name) {
  return http.post(`${BASE_URL}/`, JSON.stringify(args), {
    headers: {
      "Next-Action": actionId,
      "Content-Type": "text/plain;charset=UTF-8",
      Accept: "text/x-component",
      Origin: BASE_URL,
    },
    tags: { name },
  });
}

/**
 * 画面に含まれる TODO の ID を取り出す（RSC のペイロードに埋め込まれている）
 */
export function listTodoIds() {
  const page = http.get(`${BASE_URL}/`, { tags: { name: "setup" } });
  const ids = new Set();
  for (const m of page.body.matchAll(
    /\\?"id\\?":\\?"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/g,
  )) {
    ids.add(m[1]);
  }
  return [...ids];
}

/**
 * 書き込みの対象にする TODO を用意する。足りなければ追加する
 */
export function seedTodos(actions) {
  let ids = listTodoIds();
  for (let i = ids.length; i < SEED_TODOS; i++) {
    callAction(
      actions.addTodoAction,
      [{ title: `loadtest seed ${i + 1}`, dueDate: null }],
      "setup",
    );
  }
  if (ids.length < SEED_TODOS) {
    ids = listTodoIds();
  }
  if (ids.length === 0) {
    throw new Error("書き込みの対象にする TODO がありません");
  }
  return ids;
}

export function getPage() {
  const res = http.get(`${BASE_URL}/`, { tags: { name: "GET /" } });
  check(res, { "GET / 200": (r) => r.status === 200 });
  return res;
}

export function toggleRandomTodo(data) {
  const id = data.todoIds[Math.floor(Math.random() * data.todoIds.length)];
  const res = callAction(data.actions.toggleTodoAction, [id, Math.random() < 0.5], "action toggle");
  check(res, { "toggle 200": (r) => r.status === 200 && r.body.includes('"ok":true') });
  return res;
}

export function getHealth() {
  const res = http.get(`${BASE_URL}/api/health`, { tags: { name: "GET /api/health" } });
  check(res, { "health 200": (r) => r.status === 200 });
  return res;
}

export function getStatic(data) {
  const res = http.get(`${BASE_URL}${data.staticAsset}`, { tags: { name: "GET static" } });
  check(res, { "static 200": (r) => r.status === 200 });
  return res;
}

export function getExternalDiag() {
  const res = http.get(`${BASE_URL}/api/diag/external`, {
    tags: { name: "GET /api/diag/external" },
  });
  check(res, { "external 200": (r) => r.status === 200 });
  return res;
}
