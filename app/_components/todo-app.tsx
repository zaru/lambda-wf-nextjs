"use client";

import Link from "next/link";
import { useOptimistic, useState, useTransition } from "react";
import type { Holidays } from "@/lib/holiday-client";
import type { Todo } from "@/lib/todo-repository";
import {
  type ActionResult,
  addTodoAction,
  clearCompletedAction,
  deleteTodoAction,
  editTodoAction,
  toggleTodoAction,
} from "../actions";
import { TodoItem } from "./todo-item";

export type Filter = "all" | "active" | "completed";

export type OptimisticTodo = Todo & { pending?: boolean };

type OptimisticAction =
  | { type: "add"; todo: OptimisticTodo }
  | { type: "toggle"; id: string; completed: boolean }
  | { type: "edit"; id: string; title: string; dueDate: string | null }
  | { type: "delete"; id: string }
  | { type: "clearCompleted" };

function reducer(todos: OptimisticTodo[], action: OptimisticAction): OptimisticTodo[] {
  switch (action.type) {
    case "add":
      return [action.todo, ...todos];
    case "toggle":
      return todos.map((todo) =>
        todo.id === action.id ? { ...todo, completed: action.completed, pending: true } : todo,
      );
    case "edit":
      return todos.map((todo) =>
        todo.id === action.id
          ? { ...todo, title: action.title, dueDate: action.dueDate, pending: true }
          : todo,
      );
    case "delete":
      return todos.filter((todo) => todo.id !== action.id);
    case "clearCompleted":
      return todos.filter((todo) => !todo.completed);
  }
}

const FILTER_LABELS: Record<Filter, string> = {
  all: "すべて",
  active: "未完了",
  completed: "完了済み",
};

export function TodoApp({
  todos,
  holidays,
  filter,
}: {
  todos: Todo[];
  holidays: Holidays;
  filter: Filter;
}) {
  const [optimisticTodos, applyOptimistic] = useOptimistic<OptimisticTodo[], OptimisticAction>(
    todos,
    reducer,
  );
  const [, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [title, setTitle] = useState("");
  const [dueDate, setDueDate] = useState("");

  function mutate(action: OptimisticAction, call: () => Promise<ActionResult>) {
    setError(null);
    startTransition(async () => {
      applyOptimistic(action);
      const result = await call();
      if (!result.ok) {
        setError(result.error);
      }
    });
  }

  function handleAdd(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmed = title.trim();
    if (!trimmed) {
      return;
    }
    const input = { title: trimmed, dueDate: dueDate || null };
    const now = new Date().toISOString();
    setTitle("");
    setDueDate("");
    mutate(
      {
        type: "add",
        todo: {
          id: `pending-${now}`,
          ...input,
          completed: false,
          createdAt: now,
          updatedAt: now,
          pending: true,
        },
      },
      () => addTodoAction(input),
    );
  }

  const visibleTodos = optimisticTodos.filter((todo) => {
    if (filter === "active") return !todo.completed;
    if (filter === "completed") return todo.completed;
    return true;
  });
  const remaining = optimisticTodos.filter((todo) => !todo.completed).length;
  const hasCompleted = optimisticTodos.some((todo) => todo.completed);

  return (
    <>
      <form className="add-form" onSubmit={handleAdd}>
        <input
          type="text"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          placeholder="新しいタスクを入力…"
          maxLength={200}
          aria-label="タスクのタイトル"
        />
        <input
          type="date"
          value={dueDate}
          onChange={(event) => setDueDate(event.target.value)}
          aria-label="期限日"
        />
        <button type="submit" className="primary" disabled={!title.trim()}>
          追加
        </button>
      </form>

      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}

      <div className="toolbar">
        <nav className="filters" aria-label="フィルタ">
          {(Object.keys(FILTER_LABELS) as Filter[]).map((key) => (
            <Link
              key={key}
              href={key === "all" ? "/" : `/?filter=${key}`}
              aria-current={filter === key ? "page" : undefined}
            >
              {FILTER_LABELS[key]}
            </Link>
          ))}
        </nav>
        <span className="remaining">残り {remaining} 件</span>
      </div>

      {visibleTodos.length === 0 ? (
        <p className="empty">タスクはありません</p>
      ) : (
        <ul className="todo-list">
          {visibleTodos.map((todo) => (
            <TodoItem
              key={todo.id}
              todo={todo}
              holidayName={todo.dueDate ? holidays[todo.dueDate] : undefined}
              onToggle={(completed) =>
                mutate({ type: "toggle", id: todo.id, completed }, () =>
                  toggleTodoAction(todo.id, completed),
                )
              }
              onEdit={(input) =>
                mutate({ type: "edit", id: todo.id, ...input }, () =>
                  editTodoAction(todo.id, input),
                )
              }
              onDelete={() =>
                mutate({ type: "delete", id: todo.id }, () => deleteTodoAction(todo.id))
              }
            />
          ))}
        </ul>
      )}

      <div className="footer">
        <button
          type="button"
          className="danger"
          disabled={!hasCompleted}
          onClick={() => mutate({ type: "clearCompleted" }, () => clearCompletedAction())}
        >
          完了済みを一括削除
        </button>
      </div>
    </>
  );
}
