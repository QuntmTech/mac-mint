// The window frame inside the native Windows title bar: sidebar, toolbar and status bar.
import { HardDrive, Leaf, Lock, Sparkles, User } from "lucide-react";
import type { CleanupScan, HistoryEntry, InstalledApp, Page } from "../api/types";
import { bytes, percent, sum } from "../lib/format";
import { AREAS, PAGES, TABS } from "../lib/pages";
import { useResource } from "../state/resource";
import { useStore } from "../state/store";
import { Badge, Spinner } from "./ui";

const never = () => Promise.reject(new Error("not loaded"));

export function Sidebar() {
  const { page, go, account, overview, smartScan } = useStore();
  const cleanup = useResource<CleanupScan>("cleanup", never, false);
  const apps = useResource<InstalledApp[]>("apps", never, false);
  const history = useResource<HistoryEntry[]>("history", never, false);
  const area = PAGES[page].area;

  const meta = (p: Page): string | null => {
    if (p === "cleanup") {
      const total = cleanup.data ? sum(cleanup.data.groups.flatMap((g) => g.items), (c) => c.bytes) : 0;
      return total > 0 ? bytes(total) : null;
    }
    if (p === "apps") return apps.data?.length ? String(apps.data.length) : null;
    if (p === "history") return history.data?.length ? String(history.data.length) : null;
    if (p === "overview" && smartScan && smartScan.reclaimableBytes > 0) return null;
    return null;
  };

  const disk = overview.data?.disks.find((d) => d.isSystem) ?? overview.data?.disks[0];
  const used = disk ? disk.total - disk.free : 0;
  const fraction = disk && disk.total > 0 ? used / disk.total : 0;
  const found = smartScan ? Math.min(smartScan.reclaimableBytes, used) : 0;

  return (
    <nav className="sidebar" aria-label="MacMint">
      <div className="brand">
        <span className="brand-mark" aria-hidden="true"><Leaf size={19} strokeWidth={2.4} /></span>
        <div className="brand-text col">
          <span className="brand-name">MacMint</span>
          <span className="brand-sub">{account?.unlocked ? (account.offline ? "Pro · offline" : "Pro · this PC") : "Looking is free"}</span>
        </div>
      </div>
      <div className="eyebrow">Workspace</div>
      <div className="nav" data-tour="map">
        {AREAS.map((p) => {
          const m = PAGES[p];
          const selected = area === p;
          const value = meta(p);
          return (
            <button key={p} type="button" className="nav-item" aria-current={selected ? "page" : undefined} title={m.title}
              data-tour={`area-${p}`} onClick={() => go(lastTab[p] ?? p)}>
              <Badge icon={m.icon} swatch={m.swatch} size={24} />
              <span className="nav-label">{m.title}</span>
              {value && <span className="nav-meta">{value}</span>}
            </button>
          );
        })}
      </div>
      <div className="spacer" />
      <div className="disk-card" title={disk ? `${disk.name} (${disk.mount.replace(/\\$/, "")}): ${bytes(disk.free)} available of ${bytes(disk.total)}` : "Reading disk…"}>
        <div className="row disk-detail" style={{ gap: 7 }}>
          <HardDrive size={14} className="muted" aria-hidden="true" />
          <span className="truncate" style={{ fontSize: 12, fontWeight: 600, flex: 1 }}>{disk ? `${disk.name} (${disk.mount.replace(/\\$/, "")})` : "Reading disk…"}</span>
          {disk && <span className="caption num">{percent(fraction)} used</span>}
        </div>
        <div className="bar" style={{ height: 6, display: "flex", width: "100%" }} role="img" aria-label={disk ? `Disk ${percent(fraction)} used` : "Disk space unknown"}>
          {disk && <>
            <span style={{ width: `${(found / disk.total) * 100}%`, background: "linear-gradient(90deg, var(--sky-start), var(--indigo-start))", borderRadius: 0 }} />
            <span style={{ width: `${((used - found) / disk.total) * 100}%`, background: "var(--border-strong)", borderRadius: 0 }} />
          </>}
        </div>
        <div className="row disk-detail" style={{ gap: 4, alignItems: "baseline" }}>
          <span className="disk-free num">{disk ? bytes(disk.free) : "—"}</span>
          <span className="caption truncate">{disk ? `available of ${bytes(disk.total)}` : ""}</span>
        </div>
      </div>
      <div className="sidebar-footer">
        <button type="button" className="foot-btn grow" aria-current={page === "settings" ? "page" : undefined} title="Settings" onClick={() => go("settings")}>
          <PagesIcon page="settings" /><span className="foot-label">Settings</span>
        </button>
        <button type="button" className="foot-btn" aria-current={page === "help" ? "page" : undefined} title="Help" aria-label="Help" data-tour="help" onClick={() => go("help")}>
          <PagesIcon page="help" /><span className="foot-label sr-only">Help</span>
        </button>
      </div>
    </nav>
  );
}

/** The last tab used in each area, so coming back lands where you were. */
const lastTab: Partial<Record<Page, Page>> = {};

function PagesIcon({ page }: { page: Page }) {
  const Icon = PAGES[page].icon;
  return <Icon size={16} aria-hidden="true" />;
}

export function Toolbar() {
  const { page, go, account } = useStore();
  const m = PAGES[page];
  const tabs = TABS[m.area];
  if (tabs) lastTab[m.area] = page;
  const initials = (account?.name ?? account?.email ?? "").split(/[\s@.]+/).filter(Boolean).slice(0, 2).map((s) => s[0]!.toUpperCase()).join("");

  return (
    <div className="toolbar">
      {tabs ? (
        <div className="tabs" role="tablist" aria-label={PAGES[m.area].title}>
          {tabs.map((t) => {
            const tm = PAGES[t];
            const selected = t === page;
            return (
              <button key={t} type="button" role="tab" className="tab" aria-selected={selected} data-tour={`tab-${t}`} onClick={() => go(t)}>
                {selected ? <Badge icon={tm.icon} swatch={tm.swatch} size={18} /> : <span className="tab-icon"><tm.icon size={13} aria-hidden="true" /></span>}
                {tm.title}
              </button>
            );
          })}
        </div>
      ) : (
        <div className="crumb"><m.icon size={13} aria-hidden="true" /><span>{m.title}</span></div>
      )}
      <div className="spacer" />
      {account?.aiAvailable && page !== "assistant" && (
        <button type="button" className="ask-btn" onClick={() => go("assistant")} title="Ask MacMint">
          <Sparkles size={14} aria-hidden="true" />Ask
        </button>
      )}
      <button type="button" className="avatar-btn" data-tour="account" onClick={() => go("account")}
        title={account?.unlocked ? "Account" : "Sign in to MacMint"} aria-label={account?.unlocked ? "Account" : "Sign in to MacMint"}>
        <span className="avatar">{initials || <User size={14} />}</span>
        {account && !account.unlocked && <span className="lock-dot" aria-hidden="true"><Lock size={8} strokeWidth={3} /></span>}
      </button>
    </div>
  );
}

export function StatusBar() {
  const { status, scanning, scanProgress, cancelSmartScan, flow, cancelRun } = useStore();
  const running = flow.phase === "running" ? flow : null;
  const fraction = running?.progress && running.progress.total > 0 ? running.progress.completed / running.progress.total : null;
  return (
    <div className="statusbar" role="status" aria-live="polite">
      {scanning || running || flow.phase === "preparing" ? <Spinner color="var(--accent-text)" /> : <Leaf size={13} style={{ color: "var(--brand)" }} aria-hidden="true" />}
      {scanning && <strong>Smart Scan</strong>}
      {running && <strong>{running.plan.title}</strong>}
      <span className="truncate" style={{ flex: 1 }}>{scanning && scanProgress?.message ? scanProgress.message : status}</span>
      {running?.progress && (
        <>
          <span className="num" style={{ fontWeight: 600 }}>{running.progress.completed} of {running.progress.total}</span>
          <span className="mini-bar"><span style={{ width: `${(fraction ?? 0) * 100}%` }} /></span>
        </>
      )}
      {scanning && scanProgress && <span className="mini-bar"><span style={{ width: `${scanProgress.fraction * 100}%` }} /></span>}
      {scanning && <button className="btn secondary sm" onClick={cancelSmartScan}>Cancel</button>}
      {running && <button className="btn secondary sm" onClick={cancelRun} disabled={running.cancelling}>{running.cancelling ? "Stopping…" : "Stop"}</button>}
    </div>
  );
}
