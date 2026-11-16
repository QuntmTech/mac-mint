// App-wide state: the page being shown, settings, the account, Smart Scan, and the one flow
// that can change files (review → move to Recycle Bin → result). Pages read their own data
// through useResource; everything that more than one page shares lives here.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { call, on } from "../api/client";
import type {
  AccountStatus, OperationPlan, OperationProgress, OperationReport, Overview, Page, ScanProgress, Settings, SmartScan,
} from "../api/types";
import { errorText } from "../lib/format";
import { ALL_PAGES } from "../lib/pages";
import { invalidate, useResource, type Resource } from "./resource";

export type Flow =
  | { phase: "idle" }
  | { phase: "preparing"; title: string }
  | { phase: "review"; plan: OperationPlan; ids: string[]; busy: boolean }
  | { phase: "running"; plan: OperationPlan; progress: OperationProgress | null; cancelling: boolean }
  | { phase: "result"; report: OperationReport };

export interface Gate { purpose: "account" | "paidAction"; pending: (() => void) | null }
export interface Toast { id: number; message: string; tone: "ok" | "warn" }

interface Store {
  page: Page;
  go: (page: Page) => void;
  settings: Settings | null;
  saveSettings: (patch: Partial<Settings>) => Promise<void>;
  account: AccountStatus | null;
  setAccount: (status: AccountStatus) => void;
  overview: Resource<Overview>;

  smartScan: SmartScan | null;
  scanning: boolean;
  scanProgress: ScanProgress | null;
  scanAreasDone: string[];
  runSmartScan: () => void;
  cancelSmartScan: () => void;

  flow: Flow;
  review: (title: string, ids: string[]) => void;
  removeFromReview: (itemId: string) => void;
  confirmRun: () => void;
  cancelRun: () => void;
  closeFlow: () => void;

  requireUnlock: (action: () => void) => void;
  gate: Gate | null;
  openAccount: () => void;
  closeGate: () => void;
  accountChanged: (status: AccountStatus) => void;

  confirmEmpty: boolean;
  askEmptyRecycleBin: () => void;
  closeEmpty: () => void;
  emptyRecycleBin: () => Promise<void>;
  emptying: boolean;

  toast: Toast | null;
  notify: (message: string, tone?: "ok" | "warn") => void;

  tourStep: number | null;
  startTour: (at?: number) => void;
  setTourStep: (step: number | null) => void;
  finishTour: () => void;

  onboarding: boolean;
  finishOnboarding: (choice: "later" | "tour" | "scan") => void;

  status: string;
  busy: boolean;
}

const StoreContext = createContext<Store | null>(null);

export function useStore(): Store {
  const store = useContext(StoreContext);
  if (!store) throw new Error("useStore outside StoreProvider");
  return store;
}

const params = new URLSearchParams(window.location.search);
const startPage = (() => {
  const p = params.get("page") as Page | null;
  return p && ALL_PAGES.includes(p) ? p : "overview";
})();

/** Every cached read that an operation, restore or empty can change. */
const AFTER_CHANGE = ["overview", "cleanup", "downloads", "developer", "largeFiles:", "duplicates", "history", "leftovers:", "apps"];

export function StoreProvider({ children }: { children: ReactNode }) {
  const [page, setPage] = useState<Page>(startPage);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [account, setAccount] = useState<AccountStatus | null>(null);
  const overview = useResource<Overview>("overview", () => call("get_overview"));

  const [scanResult, setScanResult] = useState<SmartScan | null>(null);
  const [scanning, setScanning] = useState(false);
  const [scanProgress, setScanProgress] = useState<ScanProgress | null>(null);
  const [scanAreasDone, setScanAreasDone] = useState<string[]>([]);

  const [flow, setFlow] = useState<Flow>({ phase: "idle" });
  const [gate, setGate] = useState<Gate | null>(null);
  const [confirmEmpty, setConfirmEmpty] = useState(false);
  const [emptying, setEmptying] = useState(false);
  const [toast, setToast] = useState<Toast | null>(null);
  const [tourStep, setTourStep] = useState<number | null>(null);
  const [onboarding, setOnboarding] = useState(false);
  const [status, setStatus] = useState("Ready");
  const toastTimer = useRef<number>();

  const notify = useCallback((message: string, tone: "ok" | "warn" = "ok") => {
    window.clearTimeout(toastTimer.current);
    setToast({ id: Date.now(), message, tone });
    toastTimer.current = window.setTimeout(() => setToast(null), 5200);
  }, []);

  // First load: settings and account. Onboarding and the tour follow the settings.
  useEffect(() => {
    call("get_settings").then((s) => {
      setSettings(s);
      if (!s.hasOnboarded || params.get("onboarding") === "1") setOnboarding(true);
      const tour = params.get("tour");
      if (tour !== null && s.hasOnboarded) setTourStep(Math.max(0, Number(tour) || 0));
    }).catch((e) => notify(errorText(e), "warn"));
    call("account_status").then(setAccount).catch(() => undefined);
  }, [notify]);

  // Theme: ?theme= wins, then Settings; "system" leaves it to prefers-color-scheme.
  useEffect(() => {
    const forced = params.get("theme");
    const theme = forced === "dark" || forced === "light" ? forced : settings?.theme ?? "system";
    if (theme === "system") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", theme);
  }, [settings?.theme]);

  const go = useCallback((next: Page) => {
    setPage(next);
    document.querySelector(".page-scroll")?.scrollTo({ top: 0 });
  }, []);

  const saveSettings = useCallback(async (patch: Partial<Settings>) => {
    if (!settings) return;
    const next = { ...settings, ...patch };
    setSettings(next);
    try {
      setSettings(await call("save_settings", { settings: next }));
    } catch (e) {
      setSettings(settings);
      notify(errorText(e), "warn");
    }
  }, [settings, notify]);

  // MARK: Smart Scan

  const runSmartScan = useCallback(() => {
    if (scanning) return;
    setScanning(true);
    setScanAreasDone([]);
    setScanProgress({ area: "", message: "Starting Smart Scan…", fraction: 0 });
    setStatus("Smart Scan is looking. Nothing is changed.");
    let previous = "";
    const stop = on("scan-progress", (p) => {
      setScanProgress(p);
      const finished = previous;
      if (finished && finished !== p.area) setScanAreasDone((done) => (done.includes(finished) ? done : [...done, finished]));
      previous = p.area;
    });
    call("run_smart_scan")
      .then((result) => {
        setScanResult(result);
        setStatus("Smart Scan finished. Nothing was changed.");
        invalidate(["overview", "cleanup", "developer", "downloads"]);
      })
      .catch((e) => {
        const text = errorText(e);
        setStatus(text);
        if (!/cancel/i.test(text)) notify(text, "warn");
      })
      .finally(() => {
        setScanning(false);
        setScanProgress(null);
        void stop.then((unlisten) => unlisten());
      });
  }, [scanning, notify]);

  const cancelSmartScan = useCallback(() => {
    void call("cancel_scan").catch(() => undefined);
    setStatus("Stopping Smart Scan…");
  }, []);

  const smartScan = scanResult && (!overview.data?.lastSmartScan || scanResult.checkedAt >= overview.data.lastSmartScan.checkedAt)
    ? scanResult : overview.data?.lastSmartScan ?? null;

  // MARK: Account gate

  const requireUnlock = useCallback((action: () => void) => {
    if (account?.unlocked) { action(); return; }
    setStatus("Sign in with an active plan to move items. Your picks are kept.");
    setGate({ purpose: "paidAction", pending: action });
  }, [account]);

  const openAccount = useCallback(() => setGate({ purpose: "account", pending: null }), []);
  const closeGate = useCallback(() => setGate(null), []);
  const accountChanged = useCallback((next: AccountStatus) => {
    setAccount(next);
    if (next.unlocked && gate?.pending) {
      const pending = gate.pending;
      setGate(null);
      pending();
    }
  }, [gate]);

  // MARK: Review → move → result

  const review = useCallback((title: string, ids: string[]) => {
    if (ids.length === 0) return;
    requireUnlock(async () => {
      setFlow({ phase: "preparing", title });
      setStatus("Getting your review ready…");
      try {
        const plan = await call("prepare_plan", { title, ids });
        setFlow({ phase: "review", plan, ids, busy: false });
        setStatus("Review what will move. Nothing has changed yet.");
      } catch (e) {
        setFlow({ phase: "idle" });
        notify(errorText(e), "warn");
      }
    });
  }, [requireUnlock, notify]);

  const removeFromReview = useCallback(async (itemId: string) => {
    if (flow.phase !== "review") return;
    const ids = flow.ids.filter((id) => id !== itemId);
    if (ids.length === 0) { setFlow({ phase: "idle" }); return; }
    setFlow({ ...flow, busy: true });
    try {
      const plan = await call("prepare_plan", { title: flow.plan.title, ids });
      setFlow({ phase: "review", plan, ids, busy: false });
    } catch (e) {
      setFlow({ ...flow, busy: false });
      notify(errorText(e), "warn");
    }
  }, [flow, notify]);

  const confirmRun = useCallback(async () => {
    if (flow.phase !== "review" || flow.plan.items.length === 0) return;
    const plan = flow.plan;
    setFlow({ phase: "running", plan, progress: { completed: 0, total: plan.items.length, bytesMoved: 0 }, cancelling: false });
    setStatus("Moving items to the Recycle Bin. Each one is checked first.");
    const stop = on("operation-progress", (progress) => {
      setFlow((current) => (current.phase === "running" ? { ...current, progress } : current));
    });
    try {
      const report = await call("run_plan", { planId: plan.planId });
      setFlow({ phase: "result", report });
      setStatus(report.summary + ".");
    } catch (e) {
      setFlow({ phase: "idle" });
      notify(errorText(e), "warn");
      setStatus(errorText(e));
    } finally {
      void stop.then((unlisten) => unlisten());
      invalidate(AFTER_CHANGE);
    }
  }, [flow, notify]);

  const cancelRun = useCallback(() => {
    setFlow((current) => (current.phase === "running" ? { ...current, cancelling: true } : current));
    void call("cancel_operation").catch(() => undefined);
  }, []);

  const closeFlow = useCallback(() => setFlow({ phase: "idle" }), []);

  // MARK: Recycle Bin

  const askEmptyRecycleBin = useCallback(() => requireUnlock(() => setConfirmEmpty(true)), [requireUnlock]);
  const closeEmpty = useCallback(() => setConfirmEmpty(false), []);
  const emptyRecycleBin = useCallback(async () => {
    setEmptying(true);
    try {
      const message = await call("empty_recycle_bin");
      notify(message);
      setStatus(message);
      invalidate(AFTER_CHANGE);
    } catch (e) {
      notify(errorText(e), "warn");
    } finally {
      setEmptying(false);
      setConfirmEmpty(false);
    }
  }, [notify]);

  // MARK: Tour and onboarding

  const startTour = useCallback((at = 0) => { setOnboarding(false); setTourStep(at); }, []);
  const finishTour = useCallback(() => {
    setTourStep(null);
    void saveSettings({ hasTakenTour: true });
  }, [saveSettings]);

  const finishOnboarding = useCallback((choice: "later" | "tour" | "scan") => {
    setOnboarding(false);
    void saveSettings({ hasOnboarded: true });
    go("overview");
    if (choice === "tour") { setTourStep(0); runSmartScan(); }
    if (choice === "scan") runSmartScan();
  }, [saveSettings, go, runSmartScan]);

  const busy = scanning || flow.phase === "running" || flow.phase === "preparing";

  const value = useMemo<Store>(() => ({
    page, go, settings, saveSettings, account, setAccount, overview,
    smartScan, scanning, scanProgress, scanAreasDone, runSmartScan, cancelSmartScan,
    flow, review, removeFromReview, confirmRun, cancelRun, closeFlow,
    requireUnlock, gate, openAccount, closeGate, accountChanged,
    confirmEmpty, askEmptyRecycleBin, closeEmpty, emptyRecycleBin, emptying,
    toast, notify, tourStep, startTour, setTourStep, finishTour, onboarding, finishOnboarding, status, busy,
  }), [page, go, settings, saveSettings, account, overview, smartScan, scanning, scanProgress, scanAreasDone, runSmartScan,
    cancelSmartScan, flow, review, removeFromReview, confirmRun, cancelRun, closeFlow, requireUnlock, gate, openAccount,
    closeGate, accountChanged, confirmEmpty, askEmptyRecycleBin, closeEmpty, emptyRecycleBin, emptying, toast, notify,
    tourStep, startTour, finishTour, onboarding, finishOnboarding, status, busy]);

  return <StoreContext.Provider value={value}>{children}</StoreContext.Provider>;
}
