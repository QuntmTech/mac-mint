// One typed door to the engine. Inside the Tauri window it uses `invoke` and `listen`; in a
// normal browser (screenshots, design work) it uses the in-memory mock in ./mock, which is
// loaded on demand so it never ships in the real window's code path.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Commands } from "./commands";
import type { OperationProgress, ScanProgress } from "./types";

export interface Events {
  "scan-progress": ScanProgress;
  "operation-progress": OperationProgress;
}

export type CommandName = keyof Commands;
export type CommandArgs<K extends CommandName> = Parameters<Commands[K]>;
export type CommandResult<K extends CommandName> = ReturnType<Commands[K]>;

export const isTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

type MockModule = typeof import("./mock");
let mockModule: Promise<MockModule> | null = null;
function mock(): Promise<MockModule> {
  if (!mockModule) mockModule = import("./mock");
  return mockModule;
}

/** Rejections from the engine are plain-words strings; this keeps them that way. */
function normalize(error: unknown): Error {
  if (error instanceof Error) return error;
  if (typeof error === "string") return new Error(error);
  if (error && typeof error === "object" && "message" in error) return new Error(String((error as { message: unknown }).message));
  return new Error("Something went wrong. Please try again.");
}

export async function call<K extends CommandName>(name: K, ...args: CommandArgs<K>): Promise<CommandResult<K>> {
  const payload = (args[0] ?? {}) as Record<string, unknown>;
  try {
    if (isTauri) return await invoke<CommandResult<K>>(name, payload);
    const m = await mock();
    return (await m.mockInvoke(name, payload)) as CommandResult<K>;
  } catch (error) {
    throw normalize(error);
  }
}

/** Subscribes to an engine event. Resolves with an unsubscribe function. */
export async function on<E extends keyof Events>(event: E, handler: (payload: Events[E]) => void): Promise<() => void> {
  if (isTauri) return listen<Events[E]>(event, (e) => handler(e.payload));
  const m = await mock();
  return m.mockListen(event, handler as (payload: unknown) => void);
}
