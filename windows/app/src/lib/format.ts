// Plain-words formatting shared by every page. Sizes use 1024-based units, the way File
// Explorer shows them, so numbers match what people see in Windows.

const UNITS = ["bytes", "KB", "MB", "GB", "TB"];

export function bytes(value: number | null | undefined): string {
  if (value == null || !isFinite(value)) return "—";
  if (value < 1024) return value === 1 ? "1 byte" : `${Math.max(0, Math.round(value))} bytes`;
  let n = value;
  let unit = 0;
  while (n >= 1024 && unit < UNITS.length - 1) {
    n /= 1024;
    unit++;
  }
  const digits = n >= 100 ? 0 : n >= 10 ? 1 : unit >= 3 ? 2 : 1;
  return `${n.toFixed(digits).replace(/\.0+$/, "")} ${UNITS[unit]}`;
}

export function percent(fraction: number): string {
  return `${Math.round(Math.max(0, Math.min(1, fraction)) * 100)}%`;
}

export function plural(count: number, one: string, many = one + "s"): string {
  return `${count.toLocaleString()} ${count === 1 ? one : many}`;
}

const now = () => Date.now() / 1000;

/** "just now", "5 minutes ago", "yesterday", "3 days ago", "2 months ago". */
export function relative(unixSeconds: number | null | undefined): string {
  if (unixSeconds == null) return "never";
  const diff = now() - unixSeconds;
  if (diff < 0) return "just now";
  if (diff < 60) return "just now";
  const minutes = Math.floor(diff / 60);
  if (minutes < 60) return minutes === 1 ? "a minute ago" : `${minutes} minutes ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return hours === 1 ? "an hour ago" : `${hours} hours ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return "yesterday";
  if (days < 31) return `${days} days ago`;
  const months = Math.floor(days / 30.4);
  if (months < 12) return months === 1 ? "a month ago" : `${months} months ago`;
  const years = Math.floor(days / 365);
  return years === 1 ? "a year ago" : `${years} years ago`;
}

export function dateTime(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleString(undefined, {
    month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit",
  });
}

export function dateOnly(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function duration(seconds: number): string {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days > 0) return `${days} day${days === 1 ? "" : "s"}, ${hours} hr`;
  if (hours > 0) return `${hours} hr ${minutes} min`;
  return `${minutes} min`;
}

export function greeting(date = new Date()): string {
  const h = date.getHours();
  if (h >= 5 && h < 12) return "Good morning";
  if (h >= 12 && h < 18) return "Good afternoon";
  return "Good evening";
}

/** Replaces C:\Users\<name> with ~ for compact display; full path stays in the title. */
export function shortPath(path: string): string {
  return path.replace(/^[A-Z]:\\Users\\[^\\]+/i, "~");
}

export function errorText(e: unknown): string {
  if (typeof e === "string") return e;
  if (e instanceof Error) return e.message;
  if (e && typeof e === "object" && "message" in e) return String((e as { message: unknown }).message);
  return "Something went wrong. Please try again.";
}

export function sum<T>(items: T[], f: (item: T) => number): number {
  let total = 0;
  for (const item of items) total += Math.max(0, f(item) || 0);
  return total;
}
