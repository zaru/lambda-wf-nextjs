"use client";

import { useState } from "react";
import type { OptimisticTodo } from "./todo-app";

function formatDueDate(dueDate: string): string {
  const [, month, day] = dueDate.split("-");
  return `${Number(month)}/${Number(day)}`;
}

export function TodoItem({
  todo,
  holidayName,
  onToggle,
  onEdit,
  onDelete,
}: {
  todo: OptimisticTodo;
  holidayName: string | undefined;
  onToggle: (completed: boolean) => void;
  onEdit: (input: { title: string; dueDate: string | null }) => void;
  onDelete: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState(todo.title);
  const [dueDate, setDueDate] = useState(todo.dueDate ?? "");

  const className = ["todo-item", todo.completed && "completed", todo.pending && "pending"]
    .filter(Boolean)
    .join(" ");

  function startEditing() {
    setTitle(todo.title);
    setDueDate(todo.dueDate ?? "");
    setEditing(true);
  }

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmed = title.trim();
    // タイトルを空にした場合は保存しない
    if (trimmed) {
      onEdit({ title: trimmed, dueDate: dueDate || null });
    }
    setEditing(false);
  }

  if (editing) {
    return (
      <li className={className}>
        <form className="edit-form" onSubmit={handleSubmit} style={{ flex: 1 }}>
          <input
            type="text"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            maxLength={200}
            aria-label="タスクのタイトル"
            // biome-ignore lint/a11y/noAutofocus: インライン編集の開始時に入力欄へ移動する
            autoFocus
          />
          <input
            type="date"
            value={dueDate}
            onChange={(event) => setDueDate(event.target.value)}
            aria-label="期限日"
          />
          <button type="submit" className="primary">
            保存
          </button>
          <button type="button" onClick={() => setEditing(false)}>
            取消
          </button>
        </form>
      </li>
    );
  }

  return (
    <li className={className}>
      <input
        type="checkbox"
        checked={todo.completed}
        disabled={todo.pending}
        onChange={(event) => onToggle(event.target.checked)}
        aria-label={`「${todo.title}」を完了にする`}
      />
      <span className="todo-title">{todo.title}</span>
      {todo.dueDate && (
        <span className={holidayName ? "due-date holiday" : "due-date"}>
          {formatDueDate(todo.dueDate)}
          {holidayName && `（${holidayName}）`}
        </span>
      )}
      <button type="button" onClick={startEditing} disabled={todo.pending}>
        編集
      </button>
      <button
        type="button"
        className="danger"
        onClick={onDelete}
        disabled={todo.pending}
        aria-label={`「${todo.title}」を削除する`}
      >
        ×
      </button>
    </li>
  );
}
