// A tiny cache for engine reads. Pages read through `useResource`, which loads the first time
// a page is shown and keeps the result while the person moves around, so going back to a page
// is instant. After an operation the store marks keys stale and visible pages reload quietly.
import { useCallback, useEffect, useReducer, useRef, useSyncExternalStore } from "react";
import { errorText } from "../lib/format";

interface Entry {
  data?: unknown;
  error?: string;
  loading: boolean;
  stale: boolean;
  token: number;
  loadedAt?: number;
}

const entries = new Map<string, Entry>();
const listeners = new Set<() => void>();
let tokens = 0;

function notify() { listeners.forEach((l) => l()); }
function subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; }

export function load<T>(key: string, loader: () => Promise<T>): Promise<T | undefined> {
  const token = ++tokens;
  const previous = entries.get(key);
  entries.set(key, { data: previous?.data, error: undefined, loading: true, stale: false, token, loadedAt: previous?.loadedAt });
  notify();
  return loader().then(
    (data) => {
      if (entries.get(key)?.token === token) { entries.set(key, { data, loading: false, stale: false, token, loadedAt: Date.now() }); notify(); }
      return data;
    },
    (error) => {
      const current = entries.get(key);
      if (current?.token === token) { entries.set(key, { ...current, loading: false, error: errorText(error) }); notify(); }
      return undefined;
    },
  );
}

/** Marks keys (or every key starting with a prefix ending in ":") stale; shown pages reload. */
export function invalidate(keys: string[]) {
  let changed = false;
  for (const [key, entry] of entries) {
    if (keys.some((k) => (k.endsWith(":") ? key.startsWith(k) : key === k))) {
      entries.set(key, { ...entry, stale: true });
      changed = true;
    }
  }
  if (changed) notify();
}

/** Replaces cached data in place, e.g. after toggling one startup item. */
export function update<T>(key: string, change: (data: T) => T) {
  const entry = entries.get(key);
  if (!entry || entry.data === undefined) return;
  entries.set(key, { ...entry, data: change(entry.data as T) });
  notify();
}

export function peek<T>(key: string): T | undefined {
  return entries.get(key)?.data as T | undefined;
}

export interface Resource<T> {
  data: T | undefined;
  error: string | undefined;
  loading: boolean;
  /** True only before the first result: show a skeleton, not an empty list. */
  initial: boolean;
  reload: () => Promise<T | undefined>;
}

/** `key` null means "don't load yet". */
export function useResource<T>(key: string | null, loader: () => Promise<T>, auto = true): Resource<T> {
  const loaderRef = useRef(loader);
  loaderRef.current = loader;
  const entry = useSyncExternalStore(subscribe, () => (key ? entries.get(key) : undefined));
  const reload = useCallback(() => (key ? load(key, () => loaderRef.current()) : Promise.resolve(undefined)), [key]);
  useEffect(() => {
    if (!key || !auto) return;
    const current = entries.get(key);
    if (!current || (current.stale && !current.loading)) void load(key, () => loaderRef.current());
  }, [key, auto, entry?.stale]);
  return {
    data: entry?.data as T | undefined,
    error: entry?.error,
    loading: !!entry?.loading,
    initial: !entry || (entry.data === undefined && !entry.error),
    reload,
  };
}

// MARK: Selections

const selections = new Map<string, { source: unknown; ids: Set<string> }>();

/**
 * What a person has ticked on a page. It survives moving between pages and resets to the
 * engine's suggestions whenever fresh data arrives (for example after items were moved).
 */
export function useSelection(scope: string, source: unknown, defaults: () => string[]) {
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  let current = selections.get(scope);
  if (source !== undefined && (!current || current.source !== source)) {
    current = { source, ids: new Set(defaults()) };
    selections.set(scope, current);
  }
  const ids = current?.ids ?? new Set<string>();
  const set = useCallback((next: Set<string>) => {
    const existing = selections.get(scope);
    selections.set(scope, { source: existing?.source, ids: next });
    rerender();
  }, [scope]);
  return [ids, set] as const;
}

export function toggled(set: Set<string>, id: string, on?: boolean): Set<string> {
  const next = new Set(set);
  const want = on ?? !next.has(id);
  if (want) next.add(id); else next.delete(id);
  return next;
}
