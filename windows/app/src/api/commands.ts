// Command names and signatures exposed by src-tauri. `invoke(name, args)` resolves with the
// return type or rejects with a plain-words error string.
import type * as T from "./types";

export interface Commands {
  app_info(): T.AppInfo;
  get_overview(): T.Overview;
  /** Emits "scan-progress" (T.ScanProgress) while running. Can be cancelled with cancel_scan. */
  run_smart_scan(): T.SmartScan;
  cancel_scan(): void;
  scan_cleanup(): T.CleanupScan;
  scan_developer(): T.DeveloperScan;
  list_apps(): T.InstalledApp[];
  /** Starts the app's own uninstaller. Resolves with a status message. */
  uninstall_app(args: { id: string }): string;
  /** AppData folders that look like they belonged to the app (review only). */
  find_leftovers(args: { id: string }): T.Candidate[];
  list_startup(): T.StartupItem[];
  set_startup_enabled(args: { id: string; enabled: boolean }): T.StartupItem;
  open_task_manager_startup(): void;
  storage_breakdown(args: { path: string | null }): T.StorageBreakdown;
  large_files(args: { minBytes: number }): T.ScanReport<T.Candidate[]>;
  find_duplicates(): T.ScanReport<T.DuplicateGroup[]>;
  old_downloads(): T.ScanReport<T.Candidate[]>;
  performance(): T.Performance;
  set_low_priority(args: { pid: number; low: boolean }): T.ProcessInfo;
  /** Builds a reviewed plan from candidate ids found by earlier scans. */
  prepare_plan(args: { title: string; ids: string[] }): T.OperationPlan;
  /** Emits "operation-progress" (T.OperationProgress). */
  run_plan(args: { planId: string }): T.OperationReport;
  cancel_operation(): void;
  history(): T.HistoryEntry[];
  restore(args: { entryId: string; originalPath: string }): string;
  empty_recycle_bin(): string;
  get_settings(): T.Settings;
  save_settings(args: { settings: T.Settings }): T.Settings;
  account_status(): T.AccountStatus;
  sign_in(args: { email: string; password: string }): T.AccountStatus;
  sign_out(): T.AccountStatus;
  refresh_account(): T.AccountStatus;
  ai_ask(args: { question: string }): T.AIAnswer;
  check_updates(): T.UpdateInfo;
  /** Downloads the installer, checks its SHA-256 and starts it; the app then closes. */
  install_update(): string;
  reveal_path(args: { path: string }): void;
  open_url(args: { url: string }): void;
}
