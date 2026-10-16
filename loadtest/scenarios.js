// k6 の計測シナリオ（設計書 9 章）
//
//   k6 run -e SCENARIO=latency loadtest/scenarios.js
//   k6 run -e SCENARIO=steady  loadtest/scenarios.js
//   k6 run -e SCENARIO=ramp    loadtest/scenarios.js
//   k6 run -e SCENARIO=spike   loadtest/scenarios.js
//
// BASE_URL で計測先を変えられる（既定は https://wf.dev.id.basicinc.jp）。
// 祝日 API（第三者の無償 API）を叩く /api/diag/external は、latency シナリオでだけ低頻度で呼ぶ。
import {
  discover,
  getExternalDiag,
  getHealth,
  getPage,
  getStatic,
  seedTodos,
  toggleRandomTodo,
} from "./lib.js";

const SCENARIO = __ENV.SCENARIO || "latency";

// 動作確認用に、定常・レイテンシのシナリオの長さを短くできる（例: -e DURATION=30s）
const DURATION = __ENV.DURATION || "10m";

// 閲覧 80%、書き込み 20%
const mixedExec = { exec: "mixed" };

const scenarios = {
  // レイテンシ: 低負荷でエンドポイントごとの p50 / p95 / p99 を測る
  latency: {
    page: {
      executor: "constant-arrival-rate",
      exec: "page",
      rate: 2,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: 5,
    },
    action: {
      executor: "constant-arrival-rate",
      exec: "action",
      rate: 1,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: 5,
    },
    health: {
      executor: "constant-arrival-rate",
      exec: "health",
      rate: 1,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: 5,
    },
    static: {
      executor: "constant-arrival-rate",
      exec: "staticAsset",
      rate: 1,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: 5,
    },
    // 外部 API は 10 秒に 1 回だけ
    external: {
      executor: "constant-arrival-rate",
      exec: "external",
      rate: 1,
      timeUnit: "10s",
      duration: DURATION,
      preAllocatedVUs: 2,
    },
  },
  // 定常: 50 rps を 10 分間
  steady: {
    steady: {
      ...mixedExec,
      executor: "constant-arrival-rate",
      rate: 50,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: 50,
      maxVUs: 500,
    },
  },
  // 段階的な増加: 0 → 500 rps を 15 分かけて増やし、どこで悪化するかを見る
  ramp: {
    ramp: {
      ...mixedExec,
      executor: "ramping-arrival-rate",
      startRate: 0,
      timeUnit: "1s",
      preAllocatedVUs: 100,
      maxVUs: 2000,
      stages: [
        { target: 100, duration: "3m" },
        { target: 200, duration: "3m" },
        { target: 300, duration: "3m" },
        { target: 400, duration: "3m" },
        { target: 500, duration: "3m" },
      ],
    },
  },
  // スパイク: 0 → 300 rps に瞬時に上げ、5 分間維持する
  spike: {
    spike: {
      ...mixedExec,
      executor: "ramping-arrival-rate",
      startRate: 0,
      timeUnit: "1s",
      preAllocatedVUs: 300,
      maxVUs: 2000,
      stages: [
        { target: 300, duration: "5s" },
        { target: 300, duration: "5m" },
      ],
    },
  },
};

if (!scenarios[SCENARIO]) {
  throw new Error(`unknown SCENARIO: ${SCENARIO}`);
}

export const options = {
  scenarios: scenarios[SCENARIO],
  // 合格基準は初回の計測後に決める。ここでは集計する指標だけを決める
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
  thresholds: {
    // name タグごとの内訳をサマリーに出すため、閾値なしの指標を登録しておく
    "http_req_duration{name:GET /}": [],
    "http_req_duration{name:action toggle}": [],
    "http_req_duration{name:GET /api/health}": [],
    "http_req_duration{name:GET static}": [],
    "http_req_duration{name:GET /api/diag/external}": [],
    "http_req_waiting{name:GET /}": [],
    "http_req_failed{name:GET /}": [],
    "http_req_failed{name:action toggle}": [],
  },
};

export function setup() {
  const { actions, staticAsset } = discover();
  const todoIds = seedTodos(actions);
  return { actions, staticAsset, todoIds };
}

export function mixed(data) {
  if (Math.random() < 0.8) {
    getPage();
  } else {
    toggleRandomTodo(data);
  }
}

export function page() {
  getPage();
}

export function action(data) {
  toggleRandomTodo(data);
}

export function health() {
  getHealth();
}

export function staticAsset(data) {
  getStatic(data);
}

export function external() {
  getExternalDiag();
}

export function handleSummary(data) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  return {
    [`loadtest/results/${SCENARIO}-${stamp}.json`]: JSON.stringify(data, null, 2),
    stdout: textSummary(data),
  };
}

// k6 の標準のサマリーは handleSummary を定義すると出なくなるので、name タグごとの要点を出す
function textSummary(data) {
  const lines = [`scenario: ${SCENARIO}`, ""];
  for (const [key, metric] of Object.entries(data.metrics)) {
    if (!key.startsWith("http_req_duration{") && !key.startsWith("http_req_failed{")) continue;
    const v = metric.values;
    // そのシナリオで使っていないエンドポイントは出さない
    if (metric.type === "trend" && v.max === 0) continue;
    if (metric.type === "trend") {
      lines.push(
        `${key}: med=${v.med?.toFixed(1)}ms p95=${v["p(95)"]?.toFixed(1)}ms p99=${v["p(99)"]?.toFixed(1)}ms max=${v.max?.toFixed(1)}ms`,
      );
    } else {
      lines.push(`${key}: rate=${(v.rate * 100).toFixed(2)}%`);
    }
  }
  const reqs = data.metrics.http_reqs?.values;
  if (reqs) lines.push("", `requests: ${reqs.count} (${reqs.rate.toFixed(1)}/s)`);
  return `${lines.join("\n")}\n`;
}
