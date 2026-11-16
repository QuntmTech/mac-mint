// Overview (DashboardView.swift + OverviewViews.swift): greeting, the Smart Scan hero with the
// disk ring, health cards, where space can come back, recommendations, coverage and the
// Recycle Bin, then shortcuts to the other areas.
import { useState } from "react";
import {
  ChevronRight, Clock, Cpu, Eye, HardDrive, Leaf, ListChecks, Lock, Map as MapIcon, MemoryStick, Radar, ShieldCheck, Trash2, X,
} from "lucide-react";
import type { Page, Recommendation } from "../api/types";
import { bytes, greeting, percent, plural, relative, sum } from "../lib/format";
import { PAGES, type Swatch } from "../lib/pages";
import { useStore } from "../state/store";
import { RecommendationList } from "../components/Recommendations";
import { Badge, ErrorBanner, Eyebrow, Meter, Ring, SkeletonBlock, TRUST, sw } from "../components/ui";

const DAY = 86400;

export default function Overview() {
  const store = useStore();
  const { overview, smartScan, scanning, settings, account, tourStep } = store;
  const data = overview.data;
  const disk = data?.disks.find((d) => d.isSystem) ?? data?.disks[0];
  const found = smartScan ? smartScan.recommendations.filter((r) => r.bytes > 0) : [];
  const firstName = account?.name?.split(" ")[0];

  return (
    <div className="page">
      <div className="row wrap" style={{ alignItems: "flex-end", gap: 16 }}>
        <div className="col" style={{ flex: 1, gap: 3, minWidth: 260 }}>
          <Eyebrow color="var(--mint-text)">{greeting()}{firstName ? `, ${firstName}` : ""}</Eyebrow>
          <h1 style={{ fontSize: 26, letterSpacing: -0.6 }}>Overview</h1>
          <p className="muted">How your PC is doing, and where space could come back.</p>
        </div>
        <span className="pill"><ShieldCheck size={13} style={{ color: "var(--mint-text)" }} aria-hidden="true" />{TRUST.promise}</span>
      </div>

      {settings?.hasOnboarded && !settings.hasTakenTour && tourStep == null && (
        <div className="card tight row" style={{ gap: 14, borderRadius: 14 }}>
          <Badge icon={MapIcon} swatch="iris" size={34} />
          <div className="col" style={{ flex: 1, gap: 2 }}>
            <strong>New here? Take the one-minute tour.</strong>
            <span className="small muted">It shows where everything lives. Nothing is changed while it's open.</span>
          </div>
          <button className="btn plain quiet" onClick={() => void store.saveSettings({ hasTakenTour: true })}>Not Now</button>
          <button className="btn secondary" onClick={() => store.startTour(0)}>Take the Tour</button>
        </div>
      )}

      {overview.error && !data && <ErrorBanner message={overview.error} onRetry={overview.reload} title="Couldn't read this PC's details" />}

      {!data && !overview.error ? <SkeletonBlock height={236} radius={22} /> : <Hero />}

      {data ? (
        <div className="grid-cards">
          {disk && (
            <HealthCard title={`Disk ${disk.mount.replace(/\\$/, "")}`} icon={HardDrive} swatch="indigo" value={percent((disk.total - disk.free) / disk.total)}
              detail={`${bytes(disk.free)} free of ${bytes(disk.total)}`} fraction={(disk.total - disk.free) / disk.total}
              state={disk.free / disk.total < 0.1 ? "Nearly full" : disk.free / disk.total < 0.2 ? "Getting full" : "Normal"}
              strained={disk.free / disk.total < 0.2} onClick={() => store.go("storage")} />
          )}
          <HealthCard title="Memory" icon={MemoryStick} swatch="violet" value={percent(data.memory.used / data.memory.total)}
            detail={`${bytes(data.memory.used)} of ${bytes(data.memory.total)} in use`} fraction={data.memory.used / data.memory.total}
            state={data.memory.used / data.memory.total > 0.9 ? "Running low" : "Normal"} strained={data.memory.used / data.memory.total > 0.9} onClick={() => store.go("performance")} />
          <HealthCard title="CPU" icon={Cpu} swatch="sky" value={`${Math.round(data.cpuPercent)}%`} detail="How hard the processor is working"
            fraction={data.cpuPercent / 100} state={data.cpuPercent > 85 ? "Busy" : "Normal"} strained={data.cpuPercent > 85} onClick={() => store.go("performance")} />
          <HealthCard title="Recycle Bin" icon={Trash2} swatch="graphite" value={bytes(data.recycleBin.bytes)}
            detail={data.recycleBin.items ? `${plural(data.recycleBin.items, "item")} waiting` : "Empty"} fraction={null}
            state={data.recycleBin.items ? undefined : "Empty"} onClick={() => store.go("cleanup")} />
        </div>
      ) : !overview.error && (
        <div className="grid-cards">{[0, 1, 2, 3].map((i) => <SkeletonBlock key={i} height={112} radius={14} />)}</div>
      )}

      {data && disk && <StorageCard recs={found} used={disk.total - disk.free} total={disk.total} free={disk.free} scanned={!!smartScan} />}

      {found.length > 0 && !scanning && (
        <section className="col" style={{ gap: 12 }}>
          <div className="row" style={{ alignItems: "baseline" }}>
            <h2 className="section-title">Where space can come back</h2>
            <span className="spacer" />
            <span className="caption">Estimates · you review everything first</span>
          </div>
          <div className="bento">
            {found.map((rec) => <CategoryTile key={rec.id} rec={rec} />)}
          </div>
        </section>
      )}

      {data && (
        <div className="two-col">
          {smartScan && smartScan.recommendations.length > 0 ? <RecommendationList scan={smartScan} /> : <NoScanCard />}
          <div className="col" style={{ gap: 14 }}>
            <Coverage />
            {data.recycleBin.items > 0 && (
              <div className="card tight row" style={{ gap: 12 }}>
                <Badge icon={Trash2} swatch="graphite" size={32} />
                <div className="col" style={{ flex: 1, gap: 2 }}>
                  <strong className="num">{bytes(data.recycleBin.bytes)} still in the Recycle Bin</strong>
                  <span className="caption">{plural(data.recycleBin.items, "item")} · space comes back after you empty it</span>
                </div>
                <button className="btn secondary sm" onClick={store.askEmptyRecycleBin} disabled={store.busy}>
                  {!account?.unlocked && <Lock size={11} aria-hidden="true" />}Empty…
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      <div className="tools">
        <Tool page="storage" title="Explore storage" detail="What takes up room, folder by folder" />
        <Tool page="apps" title="Manage apps" detail="Apps and the data they leave behind" />
        <Tool page="startup" title="Startup apps" detail="What starts when you sign in" />
        <Tool page="developer" title="Developer workspace" detail="Build folders and package caches" />
      </div>
    </div>
  );
}

function Hero() {
  const { overview, smartScan, scanning, scanProgress, scanAreasDone, runSmartScan, cancelSmartScan, review, busy, account } = useStore();
  const data = overview.data;
  const disk = data?.disks.find((d) => d.isSystem) ?? data?.disks[0];
  const recs = smartScan?.recommendations ?? [];
  const found = sum(recs.filter((r) => r.kind !== "advice"), (r) => r.bytes);
  const safe = recs.filter((r) => r.kind === "clean");
  const safeBytes = smartScan?.reclaimableBytes ?? 0;
  const top = [...recs].filter((r) => r.kind !== "advice").sort((a, b) => b.bytes - a.bytes)[0];
  const stale = smartScan && Date.now() / 1000 - smartScan.checkedAt > DAY;
  const areaCount = smartScan?.areas.length || 7;

  const used = disk ? (disk.total - disk.free) / disk.total : 0;
  const foundShare = disk ? Math.min(used, found / disk.total) : 0;

  return (
    <section className="hero" aria-label="Smart Scan">
      <Leaf className="hero-leaf" size={220} strokeWidth={1.4} aria-hidden="true" />
      <div className="hero-text">
        <div className="hero-eyebrow"><Radar size={13} aria-hidden="true" />SMART SCAN</div>
        {scanning ? (
          <>
            <h2>Getting the full picture…</h2>
            <div className="row wrap" style={{ gap: 6 }}>
              {scanAreasDone.slice(-4).map((a) => <span key={a} className="hero-chip">✓ {a}</span>)}
              <span className="hero-chip pending"><span className="spinner" style={{ width: 11, height: 11 }} />{scanProgress?.area || "Starting"}…</span>
            </div>
          </>
        ) : found > 0 ? (
          <>
            <h2><span className="num">{bytes(found)}</span> is worth a look.</h2>
            <p>{stale ? `These are estimates from ${relative(smartScan!.checkedAt)}. Scan again for current numbers.`
              : `${top ? `${top.title} is the largest part. ` : ""}You check every item before anything moves to the Recycle Bin.`}</p>
          </>
        ) : (
          <>
            <h2>{smartScan ? "Nothing big to clear right now." : "Let's see what's taking up space."}</h2>
            <p>Smart Scan checks temp files, app caches, old downloads, build folders and the Recycle Bin. It only reads. Nothing is removed.</p>
          </>
        )}
        <div className="row wrap" style={{ gap: 8, marginTop: 4 }}>
          {!scanning && safeBytes > 0 && (
            <button className="hero-btn filled" disabled={busy} onClick={() => review("Smart Scan", Array.from(new Set(safe.flatMap((r) => r.candidateIds))))}
              title="Check the safe items before they move to the Recycle Bin">
              {account && !account.unlocked ? <Lock size={14} aria-hidden="true" /> : <ListChecks size={15} aria-hidden="true" />}Review {bytes(safeBytes)} safe
            </button>
          )}
          <button className={`hero-btn ${!scanning && safeBytes === 0 ? "filled" : ""}`} data-tour="scan" disabled={!scanning && busy}
            onClick={scanning ? cancelSmartScan : runSmartScan}>
            {scanning ? <X size={15} aria-hidden="true" /> : <Radar size={15} aria-hidden="true" />}
            {scanning ? "Cancel Scan" : smartScan ? "Scan Again" : "Run Smart Scan"}
          </button>
        </div>
        <div className="hero-meta">
          {scanning ? <><Eye size={13} aria-hidden="true" />{scanAreasDone.length} of {areaCount} checks done · only reading</>
            : smartScan ? <><Clock size={13} aria-hidden="true" />Last scanned {relative(smartScan.checkedAt)}</>
            : <><ShieldCheck size={13} aria-hidden="true" />Local scan · No account needed</>}
        </div>
      </div>
      {disk && (
        <div className="hero-ring" role="img" aria-label={`${disk.name}: ${bytes(disk.free)} available, ${bytes(disk.total - disk.free)} of ${bytes(disk.total)} used`}>
          <div style={{ position: "relative", width: 156, height: 156 }}>
            <Ring size={156} stroke={13} track="rgba(255,255,255,0.16)" segments={[
              { from: 0, to: used, color: "rgba(255,255,255,0.92)" },
              ...(foundShare > 0 ? [{ from: Math.max(0, used - foundShare), to: used, color: "#6EE7B7" }] : []),
            ]} />
            <div className="center">
              <span className="num" style={{ fontSize: 26, fontWeight: 700, letterSpacing: -0.6 }}>{bytes(disk.free)}</span>
              <span style={{ fontSize: 11.5, opacity: 0.8 }}>available on {disk.mount.replace(/\\$/, "")}</span>
            </div>
          </div>
          <div className="legend" style={{ color: "rgba(255,255,255,0.85)" }}>
            <span><i style={{ background: "#fff" }} />Used {bytes(disk.total - disk.free)}</span>
            {found > 0 && <span><i style={{ background: "#6EE7B7" }} />Worth a look</span>}
          </div>
        </div>
      )}
    </section>
  );
}

function HealthCard({ title, icon, swatch, value, detail, fraction, state, strained, onClick }: {
  title: string; icon: typeof Cpu; swatch: Swatch; value: string; detail: string; fraction: number | null; state?: string; strained?: boolean; onClick?: () => void;
}) {
  return (
    <button type="button" className="health" onClick={onClick} aria-label={`${title}: ${value}, ${detail}${state ? `, ${state}` : ""}`}>
      <div className="row" style={{ width: "100%" }}>
        <Badge icon={icon} swatch={swatch} size={22} />
        <span className="eyebrow">{title}</span>
        <span className="spacer" />
        {state && <span className={strained ? "state-warn" : "state-ok"}>{state}</span>}
      </div>
      <span className="value">{value}</span>
      <span className="small muted truncate" style={{ width: "100%" }}>{detail}</span>
      <div style={{ width: "100%" }}><Meter fraction={fraction ?? 0} swatch={swatch} /></div>
    </button>
  );
}

function StorageCard({ recs, used, total, free, scanned }: { recs: Recommendation[]; used: number; total: number; free: number; scanned: boolean }) {
  const foundTotal = sum(recs, (r) => r.bytes);
  const scale = foundTotal > used ? used / foundTotal : 1;
  const rest = Math.max(0, used - foundTotal * scale);
  return (
    <section className="card col" style={{ gap: 14, padding: "18px 20px" }}>
      <div className="row" style={{ alignItems: "baseline" }}>
        <h2 className="card-title">Storage overview</h2>
        <span className="spacer" />
        <span className="small muted num"><strong style={{ color: "var(--ink)" }}>{bytes(used)}</strong> of {bytes(total)} used</span>
      </div>
      <div className="stor-bar" aria-hidden="true">
        {recs.map((r) => <span key={r.id} className={sw(r.tone as Swatch)} style={{ width: `${(r.bytes * scale / total) * 100}%`, background: "linear-gradient(135deg, var(--sw-start), var(--sw-end))" }} />)}
        <span style={{ width: `${(rest / total) * 100}%`, background: "var(--border-strong)" }} />
      </div>
      <div className="legend-grid">
        {recs.map((r) => (
          <div key={r.id} className={`item ${sw(r.tone as Swatch)}`}>
            <i style={{ background: "linear-gradient(135deg, var(--sw-start), var(--sw-end))" }} />
            <span className="muted truncate" title={r.title}>{r.title}</span>
            <strong className="num" style={{ flex: "none" }}>{bytes(r.bytes)}</strong>
          </div>
        ))}
        <div className="item"><i style={{ background: "var(--border-strong)" }} /><span className="muted">Everything else</span><strong className="num">{bytes(rest)}</strong></div>
        <div className="item"><i style={{ background: "var(--track)" }} /><span className="muted">Free</span><strong className="num">{bytes(free)}</strong></div>
      </div>
      <p className="caption">{scanned
        ? "Colored parts are what Smart Scan found to review. Space frees up after you review items and empty the Recycle Bin."
        : "Run Smart Scan to see which parts of the used space are caches, leftovers and other things worth a look."}</p>
    </section>
  );
}

function CategoryTile({ rec }: { rec: Recommendation }) {
  const { go } = useStore();
  const Icon = PAGES[rec.page]?.icon ?? Leaf;
  const detail = rec.kind === "advice" ? "Empty it to free this space" : `${plural(rec.candidateIds.length, "item")} · ${rec.kind === "clean" ? "safe" : "needs a look"}`;
  return (
    <button type="button" className={`cat-tile ${sw(rec.tone as Swatch)}`} onClick={() => go(rec.page)} aria-label={`${rec.title}, ${bytes(rec.bytes)}. ${detail}`}>
      <Icon className="ghost" size={104} aria-hidden="true" />
      <div className="row"><span className="ico"><Icon size={16} aria-hidden="true" /></span><span className="spacer" /><ChevronRight size={14} aria-hidden="true" /></div>
      <span className="spacer" />
      <span className="big">{bytes(rec.bytes)}</span>
      <span className="truncate" style={{ fontSize: 13, fontWeight: 600, marginTop: 2 }}>{rec.title}</span>
      <span className="truncate" style={{ fontSize: 11.5, opacity: 0.88 }}>{detail}</span>
    </button>
  );
}

function Coverage() {
  const { smartScan, settings, go } = useStore();
  const [open, setOpen] = useState(false);
  const areas = smartScan?.areas ?? [];
  const full = areas.filter((a) => a.status === "checked").length;
  const partial = areas.filter((a) => a.status === "partial").length;
  const exclusions = settings?.exclusions.length ?? 0;
  const line = smartScan
    ? `${full} of ${areas.length} areas fully checked${partial ? `, ${partial} partly` : ""} · ${plural(exclusions, "exclusion")}`
    : `Not checked yet · ${plural(exclusions, "exclusion")}`;
  return (
    <div className="card tight col" style={{ gap: 10 }}>
      <div className="row" style={{ gap: 12 }}>
        <Badge icon={ListChecks} swatch="slate" size={32} />
        <div className="col" style={{ flex: 1, gap: 2 }}>
          <strong>Know what's been checked</strong>
          <span className="caption num">{line}</span>
        </div>
        <button className="btn plain" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "Hide" : "Details"}</button>
      </div>
      {open && (
        <div className="col small muted" style={{ gap: 8, paddingLeft: 44 }}>
          {areas.length === 0 && <span>Smart Scan checks temp files, app caches, logs, developer caches, old downloads, project build folders and the Recycle Bin. Run a scan to see coverage here.</span>}
          {areas.map((a) => (
            <div key={a.id} className="col" style={{ gap: 1 }}>
              <span><strong style={{ color: a.status === "checked" ? "var(--accent-text)" : "var(--warning)" }}>{statusWord(a.status)}</strong> · {a.title}{a.bytesFound > 0 ? ` · ${bytes(a.bytesFound)}` : ""}</span>
              {a.note && <span className="caption">{a.note}</span>}
            </div>
          ))}
          <span>Storage maps, large files and duplicates run separately, when you open them.</span>
          <div className="row">
            <button className="btn secondary sm" onClick={() => go("smartScan")}>Open Smart Scan</button>
            <button className="btn secondary sm" onClick={() => go("settings")}>Manage exclusions</button>
          </div>
        </div>
      )}
    </div>
  );
}

export function statusWord(status: string): string {
  return status === "checked" ? "Checked" : status === "partial" ? "Partly checked" : status === "failed" ? "Couldn't check" : "Skipped";
}

function NoScanCard() {
  const { runSmartScan, scanning } = useStore();
  return (
    <div className="card col" style={{ gap: 10, alignItems: "flex-start" }}>
      <span className="card-title">Recommended for you</span>
      <p className="small muted">{scanning ? "Smart Scan is looking. Suggestions appear here when it finishes." : "Run Smart Scan and MacMint suggests what's worth a look, ranked by space and how sure it is."}</p>
      {!scanning && <button className="btn area sw-mint" onClick={runSmartScan}><Radar size={14} aria-hidden="true" />Run Smart Scan</button>}
    </div>
  );
}

function Tool({ page, title, detail }: { page: Page; title: string; detail: string }) {
  const { go } = useStore();
  const m = PAGES[page];
  return (
    <button type="button" className={`tool ${sw(m.swatch)}`} onClick={() => go(page)}>
      <span className="tile-icon" style={{ width: 30, height: 30 }} aria-hidden="true"><m.icon size={15} /></span>
      <span className="col" style={{ flex: 1, gap: 1 }}>
        <span style={{ fontSize: 12.5, fontWeight: 600 }}>{title}</span>
        <span className="caption truncate">{detail}</span>
      </span>
      <ChevronRight size={14} className="faint" aria-hidden="true" />
    </button>
  );
}
