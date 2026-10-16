"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { errorFields, logger } from "@/lib/logger";
import {
  clearCompletedTodos,
  createTodo,
  deleteTodo,
  TodoLimitExceededError,
  TodoNotFoundError,
  updateTodo,
} from "@/lib/todo-repository";

export type ActionResult = { ok: true } | { ok: false; error: string };

const idSchema = z.uuid();
const titleSchema = z
  .string()
  .trim()
  .min(1, "タイトルを入力してください")
  .max(200, "タイトルは 200 文字以内で入力してください");
const dueDateSchema = z
  .union([z.iso.date(), z.literal("")])
  .nullish()
  .transform((value) => value || null);

async function run(fn: () => Promise<unknown>): Promise<ActionResult> {
  try {
    await fn();
    revalidatePath("/");
    return { ok: true };
  } catch (error) {
    if (error instanceof z.ZodError) {
      return { ok: false, error: error.issues[0]?.message ?? "入力が正しくありません" };
    }
    if (error instanceof TodoLimitExceededError || error instanceof TodoNotFoundError) {
      return { ok: false, error: error.message };
    }
    logger.error("server action failed", errorFields(error));
    return { ok: false, error: "処理に失敗しました。時間をおいて再度お試しください" };
  }
}

export async function addTodoAction(input: {
  title: string;
  dueDate: string | null;
}): Promise<ActionResult> {
  return run(() =>
    createTodo({
      title: titleSchema.parse(input.title),
      dueDate: dueDateSchema.parse(input.dueDate),
    }),
  );
}

export async function toggleTodoAction(id: string, completed: boolean): Promise<ActionResult> {
  return run(() => updateTodo(idSchema.parse(id), { completed: z.boolean().parse(completed) }));
}

export async function editTodoAction(
  id: string,
  input: { title: string; dueDate: string | null },
): Promise<ActionResult> {
  return run(() =>
    updateTodo(idSchema.parse(id), {
      title: titleSchema.parse(input.title),
      dueDate: dueDateSchema.parse(input.dueDate),
    }),
  );
}

export async function deleteTodoAction(id: string): Promise<ActionResult> {
  return run(() => deleteTodo(idSchema.parse(id)));
}

export async function clearCompletedAction(): Promise<ActionResult> {
  return run(() => clearCompletedTodos());
}
