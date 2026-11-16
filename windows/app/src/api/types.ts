// The contract between the window (this UI) and the engine (src-tauri, Rust).
// Every type mirrors a Rust struct serialized with serde camelCase. Sizes are bytes, times are
// Unix seconds. Paths are plain Windows path strings.

export type Risk = "safe" | "review" | "restricted";
export type CleanupCategory = "tempFiles" | "appCaches" | "logsAndReports" | "developerCaches" | "installers";

export interface ScanIssue { area: string; path: string | null; message: string }
export interface ScanReport<T> { value: T; issues: ScanIssue[]; cancelled: boolean }

/** Something a scan found that can be moved to the Recycle Bin. `id` is what the UI sends back. */
export interface Candidate {
  id: string;
  path: string;
  name: string;
  /** Short label, e.g. "Chrome", "npm", "Temp". */
  group: string;
  detail: string;
  bytes: number;
  risk: Risk;
  /** Why MacMint thinks it can go (or why it's only for review). */
  reason: string;
  /** Preselected in the review list. Only ever true for "safe" items whose owner isn't running. */
  selected: boolean;
  /** e.g. "Chrome is open: quit it first". Null when nothing blocks it. */
  blockedBy: string | null;
  ownerName: string | null;
  modified: number | null;
  category: CleanupCategory | "developer" | "largeFile" | "duplicate" | "download" | "leftover";
}

export interface CleanupGroup {
  category: CleanupCategory;
  title: string;
  /** One sentence in plain words. */
  summary: string;
  items: Candidate[];
}

export interface CleanupScan { checkedAt: number; groups: CleanupGroup[]; issues: ScanIssue[]; recycleBin: RecycleBinInfo }

export interface DeveloperItem extends Candidate {
  project: string;
  projectName: string;
  tool: string;
  kind: "generatedOutput" | "installedDependencies";
  lastActivity: number | null;
}
export interface DeveloperScan { checkedAt: number; items: DeveloperItem[]; caches: Candidate[]; issues: ScanIssue[] }

export interface RecycleBinInfo { bytes: number; items: number }

export interface DiskInfo { name: string; mount: string; total: number; free: number; isSystem: boolean }

export interface Overview {
  computerName: string;
  osVersion: string;
  disks: DiskInfo[];
  memory: { total: number; used: number };
  cpuPercent: number;
  uptimeSeconds: number;
  recycleBin: RecycleBinInfo;
  lastSmartScan: SmartScan | null;
}

export type AreaStatus = "checked" | "partial" | "failed" | "skipped";
export interface ScanArea { id: string; title: string; status: AreaStatus; bytesFound: number; note: string | null }

export interface Recommendation {
  id: string;
  title: string;
  /** Plain-words explanation, honest about what was checked. */
  detail: string;
  bytes: number;
  /** Candidate ids this recommendation would review. Empty for advice-only items. */
  candidateIds: string[];
  kind: "clean" | "review" | "advice";
  /** Page to open for details: "cleanup" | "developer" | "apps" | "startup" | "storage" | "performance". */
  page: Page;
  tone: "mint" | "sky" | "amber" | "violet" | "slate";
}

export interface SmartScan {
  checkedAt: number;
  areas: ScanArea[];
  recommendations: Recommendation[];
  /** Total of all "clean" recommendations. */
  reclaimableBytes: number;
}

export interface ScanProgress { area: string; message: string; fraction: number }

export interface InstalledApp {
  id: string;
  name: string;
  publisher: string | null;
  version: string | null;
  bytes: number | null;
  installDate: string | null;
  location: string | null;
  icon: string | null; // data: URL when available
  canUninstall: boolean;
  running: boolean;
  scope: "currentUser" | "allUsers";
}

export interface StartupItem {
  id: string;
  name: string;
  command: string;
  location: "currentUserRun" | "allUsersRun" | "startupFolder" | "allUsersStartupFolder";
  enabled: boolean;
  /** False for all-users entries (they need admin); the UI offers "Open Task Manager" instead. */
  canToggle: boolean;
  publisher: string | null;
}

export interface FolderUsage { path: string; name: string; bytes: number; isDir: boolean; files: number; unreadable: number }
export interface StorageBreakdown { path: string; bytes: number; children: FolderUsage[] }

export interface DuplicateGroup { id: string; bytes: number; files: Candidate[] }

export interface ProcessInfo { pid: number; name: string; cpuPercent: number; memory: number; lowered: boolean; canLower: boolean }
export interface Performance {
  cpuPercent: number;
  memory: { total: number; used: number };
  processes: ProcessInfo[];
  startupEnabled: number;
  uptimeSeconds: number;
}

export interface PlanItem { id: string; path: string; name: string; expectedBytes: number; reason: string; source: string; needsAttention: boolean }
export interface OperationPlan { planId: string; title: string; items: PlanItem[]; rejected: { path: string; message: string }[]; totalBytes: number }

export type OutcomeStatus = "moved" | "skipped" | "failed" | "notAttempted" | "inFlight" | "uncertain";
export interface ItemOutcome { item: PlanItem; status: OutcomeStatus; message: string | null }
export interface OperationReport { id: string; title: string; startedAt: number; finishedAt: number | null; outcomes: ItemOutcome[]; cancelled: boolean; summary: string; bytesMoved: number }
export interface OperationProgress { completed: number; total: number; bytesMoved: number }

export interface HistoryReceipt { originalPath: string; bytes: number; trashedAt: number; restored: boolean }
export interface HistoryEntry { id: string; title: string; date: number; bytes: number; notes: string; receipts: HistoryReceipt[]; uncertain: string[] }

export interface Settings {
  theme: "system" | "light" | "dark";
  exclusions: string[];
  hasOnboarded: boolean;
  hasTakenTour: boolean;
  aiEnabled: boolean;
  checkUpdatesAutomatically: boolean;
}

export interface AccountStatus {
  signedIn: boolean;
  email: string | null;
  name: string | null;
  /** "Pro" etc. Null when there's no active plan. */
  plan: string | null;
  /** True when moving files is allowed (active plan, this PC activated). */
  unlocked: boolean;
  offline: boolean;
  deviceName: string;
  message: string | null;
  aiAvailable: boolean;
}

export interface UpdateInfo { current: string; build: number; latest: string | null; latestBuild: number | null; available: boolean; notes: string | null; publishedAt: string | null; message: string | null }

export interface AppInfo { version: string; build: number; platform: string; dataFolder: string }

export interface AIAnswer { answer: string; remaining: number | null }

export type Page =
  | "overview" | "smartScan" | "cleanup" | "developer" | "apps" | "startup" | "storage"
  | "largeFiles" | "duplicates" | "performance" | "history" | "settings" | "account" | "assistant" | "help";
