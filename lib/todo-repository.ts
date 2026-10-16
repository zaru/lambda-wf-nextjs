import { v7 as uuidv7 } from "uuid";
import { withValkey } from "./valkey";

// ハッシュタグ {todo} を付けて、関連するキーを同じスロットに載せる
export const TODO_KEY = "{todo}:items";
export const MAX_TODOS = 500;

export type Todo = {
  id: string;
  title: string;
  dueDate: string | null;
  completed: boolean;
  createdAt: string;
  updatedAt: string;
};

export class TodoLimitExceededError extends Error {
  constructor() {
    super(`TODO は ${MAX_TODOS} 件までです`);
    this.name = "TodoLimitExceededError";
  }
}

export class TodoNotFoundError extends Error {
  constructor(id: string) {
    super(`TODO が見つかりません: ${id}`);
    this.name = "TodoNotFoundError";
  }
}

function parse(raw: string): Todo {
  return JSON.parse(raw) as Todo;
}

export async function listTodos(): Promise<Todo[]> {
  const all = await withValkey((client) => client.hgetall(TODO_KEY));
  return Object.values(all)
    .map(parse)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

export async function createTodo(input: { title: string; dueDate: string | null }): Promise<Todo> {
  return withValkey(async (client) => {
    const count = await client.hlen(TODO_KEY);
    if (count >= MAX_TODOS) {
      throw new TodoLimitExceededError();
    }
    const now = new Date().toISOString();
    const todo: Todo = {
      id: uuidv7(),
      title: input.title,
      dueDate: input.dueDate,
      completed: false,
      createdAt: now,
      updatedAt: now,
    };
    await client.hset(TODO_KEY, todo.id, JSON.stringify(todo));
    return todo;
  });
}

export async function updateTodo(
  id: string,
  patch: Partial<Pick<Todo, "title" | "dueDate" | "completed">>,
): Promise<Todo> {
  return withValkey(async (client) => {
    const raw = await client.hget(TODO_KEY, id);
    if (!raw) {
      throw new TodoNotFoundError(id);
    }
    // 同時更新は後勝ちでよい（デモ用途）
    const todo: Todo = { ...parse(raw), ...patch, updatedAt: new Date().toISOString() };
    await client.hset(TODO_KEY, id, JSON.stringify(todo));
    return todo;
  });
}

export async function deleteTodo(id: string): Promise<void> {
  await withValkey((client) => client.hdel(TODO_KEY, id));
}

export async function clearCompletedTodos(): Promise<number> {
  return withValkey(async (client) => {
    const all = await client.hgetall(TODO_KEY);
    const completedIds = Object.values(all)
      .map(parse)
      .filter((todo) => todo.completed)
      .map((todo) => todo.id);
    if (completedIds.length === 0) {
      return 0;
    }
    return client.hdel(TODO_KEY, ...completedIds);
  });
}
