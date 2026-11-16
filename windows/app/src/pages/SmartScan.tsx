// Smart Scan: one careful look at the usual places space hides. Shows each area as it is
// checked, then what was found and what MacMint suggests (SmartCareViews.swift).
import { AlertTriangle, CheckCircle2, CircleSlash, Clock, Lock, ListChecks, Radar, X, XCircle } from "lucide-react";
import type { AreaStatus } from "../api/types";
import { bytes, relative } from "../lib/format";
import { useStore } from "../state/store";
import { RecommendationList } from "../components/Recommendations";
import { Chip, EmptyState, LoadingState, PageHeader, TrustLine } from "../components/ui";
import { statusWord } from "./Overview";

const AREA_NAMES = ["Temporary files", "App caches", "Logs and crash reports", "Developer caches", "Installers and old downloads", "Project build folders", "Recycle Bin"];

export default function SmartScan() {
  const { smartScan, scanning, scanProgress, scanAreasDone, runSmartScan, cancelSmartScan, review, busy, account, overview } = useStore();
  const safe = smartScan?.recommendations.filter((r) => r.kind === "clean") ?? [];

  return (
    <div className="page">
      <PageHeader title="Smart Scan" icon={Radar} swatch="mint" subtitle="One careful look at the places space usually hides. It only reads.">
        {scanning
          ? <button className="btn secondary" onClick={cancelSmartScan}><X size={14} />Cancel</button>
          : <button className="btn area" onClick={runSmartScan} disabled={busy}><Radar size={14} />{smartScan ? "Scan Again" : "Run Smart Scan"}</button>}
      </PageHeader>

      {scanning ? (
        <div className="col" style={{ gap: 14 }}>
          <LoadingState title="Looking around your PC…" detail="Smart Scan checks known places for temp files, caches, old downloads and build folders. Results appear when every check is done."
            icon={Radar} swatch="mint" progress={scanProgress?.fraction ?? 0} status={`${scanAreasDone.length} of ${AREA_NAMES.length} checks done`} rows={0} onCancel={cancelSmartScan} />
          <div className="card flush" style={{ maxWidth: 660, width: "100%", margin: "0 auto" }}>
            {AREA_NAMES.map((name) => {
              const done = scanAreasDone.includes(name);
              const current = scanProgress?.area === name;
              return (
                <div key={name} className="list-row" style={{ minHeight: 44 }}>
                  {done ? <CheckCircle2 size={18} style={{ color: "var(--accent-text)" }} aria-hidden="true" />
                    : current ? <span className="spinner" style={{ color: "var(--accent-text)", width: 16, height: 16 }} />
                    : <Clock size={18} className="faint" aria-hidden="true" />}
                  <span style={{ flex: 1, fontWeight: current ? 600 : 500 }}>{name}</span>
                  <span className="caption">{done ? "Checked" : current ? "Checking…" : "Waiting"}</span>
                </div>
              );
            })}
          </div>
        </div>
      ) : !smartScan ? (
        overview.initial ? <LoadingState title="Reading your last scan…" detail="One moment." swatch="mint" rows={3} /> :
        <EmptyState icon={Radar} swatch="mint" title="Run your first Smart Scan"
          detail="It checks temp files, app caches, logs, old downloads, project build folders and the Recycle Bin. It usually takes under a minute."
          action={{ label: "Run Smart Scan", onClick: runSmartScan, disabled: busy }} />
      ) : (
        <>
          <div className="card row wrap" style={{ gap: 18, alignItems: "center" }}>
            <div className="col" style={{ flex: "1 1 260px", gap: 4 }}>
              <span className="eyebrow" style={{ color: "var(--mint-text)" }}>Last scan · {relative(smartScan.checkedAt)}</span>
              <span className="num" style={{ fontSize: 30, fontWeight: 700, letterSpacing: -0.8 }}>{bytes(smartScan.reclaimableBytes)}</span>
              <span className="small muted">can come back safely. Caches and build folders rebuild on their own.</span>
            </div>
            {safe.length > 0 && (
              <button className="btn commit" disabled={busy} onClick={() => review("Smart Scan", Array.from(new Set(safe.flatMap((r) => r.candidateIds))))}>
                {account && !account.unlocked ? <Lock size={13} /> : <ListChecks size={14} />}Review Safe Items…
              </button>
            )}
          </div>

          <section className="col" style={{ gap: 10 }}>
            <h2 className="section-title">What was checked</h2>
            <div className="card flush">
              {smartScan.areas.map((a) => (
                <div key={a.id} className="list-row" style={{ alignItems: "flex-start", paddingTop: 11, paddingBottom: 11 }}>
                  <StatusIcon status={a.status} />
                  <div className="col" style={{ flex: 1, gap: 2 }}>
                    <span className="row-title">{a.title}</span>
                    {a.note && <span className="row-sub">{a.note}</span>}
                  </div>
                  <StatusChip status={a.status} />
                  <span className="size" style={{ minWidth: 74 }}>{a.bytesFound > 0 ? bytes(a.bytesFound) : "—"}</span>
                </div>
              ))}
            </div>
            <TrustLine />
          </section>

          {smartScan.recommendations.length > 0 && <RecommendationList scan={smartScan} />}
        </>
      )}
    </div>
  );
}

function StatusIcon({ status }: { status: AreaStatus }) {
  const style = { flex: "none", marginTop: 1 } as const;
  if (status === "checked") return <CheckCircle2 size={18} style={{ ...style, color: "var(--accent-text)" }} aria-hidden="true" />;
  if (status === "partial") return <AlertTriangle size={18} style={{ ...style, color: "var(--warning)" }} aria-hidden="true" />;
  if (status === "failed") return <XCircle size={18} style={{ ...style, color: "var(--danger)" }} aria-hidden="true" />;
  return <CircleSlash size={18} style={{ ...style, color: "var(--ink3)" }} aria-hidden="true" />;
}

function StatusChip({ status }: { status: AreaStatus }) {
  const swatch = status === "checked" ? "mint" : status === "partial" ? "amber" : status === "failed" ? "rose" : "slate";
  return <Chip swatch={swatch}>{statusWord(status)}</Chip>;
}
