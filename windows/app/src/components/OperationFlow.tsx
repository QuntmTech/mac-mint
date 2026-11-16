// The only path that changes files: a final check listing every item, the total and anything
// left out with its reason → "Move to Recycle Bin" → progress with Stop → a result summary
// with skipped items and a link to History. Mirrors OperationViews.swift.
import { useState, type ReactNode } from "react";
import {
  AlertTriangle, Undo2, Check, ChevronDown, ChevronRight, Hammer, Copy, Download, FileBox, FileText, FolderOpen, Hand,
  LayoutGrid, ListChecks, ShieldCheck, Sparkles, Trash2, X, type LucideIcon,
} from "lucide-react";
import { call } from "../api/client";
import type { OperationPlan, PlanItem } from "../api/types";
import { bytes, plural, sum } from "../lib/format";
import type { Swatch } from "../lib/pages";
import { useStore } from "../state/store";
import { Badge, Chip, Dialog, Eyebrow, SheetHeader, Spinner, TileIcon } from "./ui";

export function sourceLook(source: string): { icon: LucideIcon; swatch: Swatch } {
  switch (source) {
    case "Developer": return { icon: Hammer, swatch: "orange" };
    case "Large Files": return { icon: FileBox, swatch: "indigo" };
    case "Duplicates": return { icon: Copy, swatch: "indigo" };
    case "Old downloads": return { icon: Download, swatch: "teal" };
    case "App leftovers": return { icon: LayoutGrid, swatch: "violet" };
    default: return { icon: Sparkles, swatch: "sky" };
  }
}

function reveal(path: string) { void call("reveal_path", { path }).catch(() => undefined); }

export function OperationFlow() {
  const store = useStore();
  const { flow } = store;
  if (flow.phase === "preparing") {
    return (
      <Dialog label="Getting your review ready" size="sm">
        <div className="sheet-body" style={{ alignItems: "center", textAlign: "center", padding: "32px 24px", gap: 12 }}>
          <Spinner color="var(--accent-text)" />
          <strong style={{ fontSize: 15 }}>Getting your review ready…</strong>
          <span className="muted small">MacMint checks each item once more. Nothing has moved.</span>
        </div>
      </Dialog>
    );
  }
  if (flow.phase === "review") return <ReviewSheet plan={flow.plan} busy={flow.busy} />;
  if (flow.phase === "running") {
    const p = flow.progress;
    const fraction = p && p.total > 0 ? p.completed / p.total : 0;
    return (
      <Dialog label="Moving to the Recycle Bin" size="md">
        <SheetHeader icon={Trash2} swatch="mint" eyebrow={flow.plan.title} title="Moving to the Recycle Bin…"
          subtitle="Each item is checked once more right before it moves. You can stop at any time." />
        <div className="sheet-body sw-mint" style={{ gap: 10 }}>
          <div className="progress" style={{ height: 8 }} role="progressbar" aria-valuenow={Math.round(fraction * 100)} aria-valuemin={0} aria-valuemax={100} aria-label="Moving items">
            <span style={{ width: `${Math.max(3, fraction * 100)}%` }} />
          </div>
          <div className="row small">
            <span className="num" style={{ fontWeight: 600 }}>{p ? `${p.completed} of ${p.total}` : "Starting…"}</span>
            <span className="spacer" />
            <span className="muted num">{bytes(p?.bytesMoved ?? 0)} moved</span>
          </div>
        </div>
        <div className="sheet-foot">
          <span className="small muted" style={{ flex: 1 }}>Items that already moved stay in the Recycle Bin with a receipt.</span>
          <button className="btn secondary" onClick={store.cancelRun} disabled={flow.cancelling}>{flow.cancelling ? "Stopping…" : "Stop"}</button>
        </div>
      </Dialog>
    );
  }
  if (flow.phase === "result") return <ResultSheet />;
  return null;
}

function ReviewSheet({ plan, busy }: { plan: OperationPlan; busy: boolean }) {
  const { closeFlow, removeFromReview, confirmRun } = useStore();
  const [showRejected, setShowRejected] = useState(plan.items.length === 0);
  const empty = plan.items.length === 0;
  const care = plan.items.filter((i) => i.needsAttention);
  const easy = plan.items.filter((i) => !i.needsAttention);
  const sources = Array.from(new Set(plan.items.map((i) => i.source)));

  return (
    <Dialog label={`Final check: ${plan.title}`} onClose={closeFlow}>
      <SheetHeader icon={ListChecks} swatch="mint" eyebrow={`Final check · ${plan.title}`}
        title={empty ? "Nothing can be moved" : `Move ${plural(plan.items.length, "item")} to the Recycle Bin?`}
        subtitle={empty ? "Everything you picked was left out, for the reasons below."
          : `${bytes(plan.totalBytes)} · you can restore any of it from History while it's in the Recycle Bin.`} />
      <div className="divider" />
      <div className="sheet-body" aria-busy={busy}>
        {!empty && (
          <div className="col" style={{ gap: 8 }}>
            {easy.length > 0 && <Breakdown chip={<Chip swatch="mint" icon={ShieldCheck}>Safe</Chip>} text={`${plural(easy.length, "item")} · caches and files that rebuild on their own`} total={sum(easy, (i) => i.expectedBytes)} />}
            {care.length > 0 && <Breakdown warn chip={<Chip swatch="amber" icon={AlertTriangle}>Review</Chip>} text={`${plural(care.length, "item")} · personal files, or data that may not come back`} total={sum(care, (i) => i.expectedBytes)} />}
          </div>
        )}
        {plan.rejected.length > 0 && (
          <div className="card" style={{ background: "var(--panel)", boxShadow: "none", padding: 12 }}>
            <button className="row" style={{ border: 0, background: "transparent", padding: 0, width: "100%", color: "var(--warning)", fontWeight: 600 }}
              aria-expanded={showRejected} onClick={() => setShowRejected(!showRejected)}>
              {showRejected ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              <Hand size={14} aria-hidden="true" />
              {plural(plan.rejected.length, "item")} won't be moved
            </button>
            {showRejected && (
              <ul className="col" style={{ listStyle: "none", margin: "8px 0 0", padding: "0 0 0 22px", gap: 8 }}>
                {plan.rejected.map((r) => (
                  <li key={r.path} className="col" style={{ gap: 1 }}>
                    <span className="small" style={{ fontWeight: 600 }}>{r.path.split("\\").pop() || r.path}</span>
                    <span className="caption" style={{ color: "var(--ink2)" }}>{r.message}</span>
                    <span className="mono faint truncate" title={r.path}>{r.path}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
        {!empty && <p className="small muted">Remove anything you want to keep. Only the items below will move.</p>}
        {sources.map((source) => {
          const items = plan.items.filter((i) => i.source === source);
          const look = sourceLook(source);
          return (
            <div key={source} className="card flush" style={{ borderRadius: 14 }}>
              <div className="row" style={{ padding: "11px 16px", background: "var(--panel)", gap: 10 }}>
                <Badge icon={look.icon} swatch={look.swatch} size={22} />
                <strong style={{ fontSize: 13 }}>{source}</strong>
                <span className="caption num">{plural(items.length, "item")}</span>
                <span className="spacer" />
                <span className="size">{bytes(sum(items, (i) => i.expectedBytes))}</span>
              </div>
              {items.map((item) => <PlanRow key={item.id} item={item} swatch={look.swatch} onRemove={() => removeFromReview(item.id)} disabled={busy} />)}
            </div>
          );
        })}
      </div>
      {!empty && (
        <div className="promises" aria-label="How moving works">
          <PromiseItem icon={Trash2} text="Goes to the Recycle Bin, not deleted" />
          <PromiseItem icon={ShieldCheck} text="Each item is checked again right before it moves" />
          <PromiseItem icon={FileText} text="A receipt is saved in History" />
          <PromiseItem icon={Undo2} text="Restore while it's in the Recycle Bin" />
        </div>
      )}
      <div className="sheet-foot">
        <span className="small muted" style={{ flex: "1 1 200px" }}>Nothing has moved yet.</span>
        <button className="btn secondary" onClick={closeFlow}>{empty ? "Close" : "Cancel"}</button>
        {!empty && (
          <button className="btn commit" onClick={confirmRun} disabled={busy} data-autofocus>
            {busy ? <Spinner /> : <Trash2 size={14} aria-hidden="true" />}
            Move {plural(plan.items.length, "Item")} to Recycle Bin
          </button>
        )}
      </div>
    </Dialog>
  );
}

function Breakdown({ chip, text, total, warn }: { chip: ReactNode; text: string; total: number; warn?: boolean }) {
  return (
    <div className="row" style={{ padding: "9px 12px", borderRadius: 11, background: warn ? "var(--warning-tint)" : "var(--panel)", gap: 10 }}>
      {chip}
      <span className="small muted" style={{ flex: 1 }}>{text}</span>
      <span className="size">{bytes(total)}</span>
    </div>
  );
}

function PromiseItem({ icon: Icon, text }: { icon: LucideIcon; text: string }) {
  return <div className="promise"><Icon size={17} aria-hidden="true" /><span>{text}</span></div>;
}

function PlanRow({ item, swatch, onRemove, disabled }: { item: PlanItem; swatch: Swatch; onRemove: () => void; disabled: boolean }) {
  return (
    <div className="list-row" style={{ alignItems: "flex-start", padding: "10px 16px" }}>
      <TileIcon icon={item.needsAttention ? AlertTriangle : sourceLook(item.source).icon} swatch={item.needsAttention ? "amber" : swatch} />
      <div className="col" style={{ flex: 1, gap: 2 }}>
        <div className="row" style={{ gap: 6 }}>
          <span className="row-title truncate">{item.name}</span>
          {item.needsAttention && <Chip swatch="amber" icon={AlertTriangle}>Review</Chip>}
        </div>
        <span className="mono faint truncate" title={item.path}>{item.path}</span>
        <span className="small muted">{item.reason}</span>
      </div>
      <span className="size" style={{ paddingTop: 6 }}>{bytes(item.expectedBytes)}</span>
      <button className="icon-btn" title="Show in File Explorer" aria-label={`Show ${item.name} in File Explorer`} onClick={() => reveal(item.path)}><FolderOpen size={14} /></button>
      <button className="icon-btn" title="Keep this item" aria-label={`Keep ${item.name}: remove it from this review`} onClick={onRemove} disabled={disabled}><X size={14} /></button>
    </div>
  );
}

function ResultSheet() {
  const { flow, closeFlow, go } = useStore();
  if (flow.phase !== "result") return null;
  const report = flow.report;
  const movedCount = report.outcomes.filter((o) => o.status === "moved").length;
  const problems = report.outcomes.filter((o) => o.status === "skipped" || o.status === "failed" || o.status === "uncertain" || o.status === "inFlight");
  const notAttempted = report.outcomes.filter((o) => o.status === "notAttempted");
  const allGood = problems.length === 0 && !report.cancelled && notAttempted.length === 0;
  const swatch: Swatch = allGood ? "mint" : "amber";
  const headline = movedCount === 0 ? "Nothing was moved" : movedCount === 1 ? "1 item is in the Recycle Bin" : `${movedCount} items are in the Recycle Bin`;

  return (
    <Dialog label="Result" onClose={closeFlow} size="md" swatch={swatch}>
      <div className={`col ${`sw-${swatch}`}`} style={{ alignItems: "center", textAlign: "center", gap: 8, padding: "28px 28px 14px",
        background: `radial-gradient(ellipse at top, var(--${swatch}-tint), var(--elevated) 70%)` }}>
        <span className="badge" style={{ width: 64, height: 64, borderRadius: "50%", boxShadow: `0 0 0 8px var(--${swatch}-tint)`, marginBottom: 8 }} aria-hidden="true">
          {allGood ? <Check size={30} strokeWidth={3} /> : <AlertTriangle size={28} strokeWidth={2.6} />}
        </span>
        <Eyebrow color={`var(--${swatch}-text)`}>{allGood ? "Done" : report.cancelled ? "Stopped" : "Finished with notes"}</Eyebrow>
        <h2 style={{ fontSize: 21, letterSpacing: -0.4 }}>{headline}</h2>
        {movedCount > 0 && <span className="num" style={{ fontSize: 34, fontWeight: 700, letterSpacing: -0.8, color: "var(--mint-text)" }}>{bytes(report.bytesMoved)}</span>}
        {(!allGood || movedCount === 0) && <p className="small muted">{report.summary}.</p>}
        {movedCount > 0 && <p className="small muted" style={{ maxWidth: 440 }}>That space comes back when you empty the Recycle Bin. Until then, you can restore these items from History.</p>}
      </div>
      <div className="row" style={{ justifyContent: "center", paddingBottom: 16, gap: 8 }}>
        {movedCount > 0 && <span className="chip sw-slate"><FileText size={11} />{plural(movedCount, "receipt")} saved</span>}
        <span className="chip sw-slate"><AlertTriangle size={11} />{plural(problems.length, "problem")}</span>
      </div>
      {(problems.length > 0 || notAttempted.length > 0) && (
        <>
          <div className="divider" />
          <div className="sheet-body" style={{ maxHeight: 280 }}>
            {problems.length > 0 && <Eyebrow>Left in place</Eyebrow>}
            {problems.map((o) => (
              <div key={o.item.id} className="col" style={{ padding: "9px 12px", borderRadius: 11, background: "var(--panel)", gap: 2 }}>
                <span className="row-title">{o.item.name}</span>
                <span className="small muted">{o.message ?? "Skipped."}</span>
              </div>
            ))}
            {notAttempted.length > 0 && <Eyebrow style={{ marginTop: 6 }}>Not started (you stopped the move)</Eyebrow>}
            {notAttempted.map((o) => (
              <div key={o.item.id} style={{ padding: "8px 12px", borderRadius: 11, background: "var(--panel)" }} className="small">{o.item.name}</div>
            ))}
          </div>
        </>
      )}
      <div className="sheet-foot">
        <button className="btn plain" onClick={() => { closeFlow(); go("history"); }}>Show History</button>
        <span className="spacer" />
        <button className="btn commit" onClick={closeFlow} data-autofocus>Done</button>
      </div>
    </Dialog>
  );
}

export function EmptyRecycleBinDialog() {
  const { confirmEmpty, closeEmpty, emptyRecycleBin, emptying, overview } = useStore();
  if (!confirmEmpty) return null;
  const bin = overview.data?.recycleBin;
  return (
    <Dialog label="Empty the Recycle Bin" onClose={emptying ? undefined : closeEmpty} size="sm" swatch="rose">
      <SheetHeader icon={Trash2} swatch="rose" eyebrow="This can't be undone" title="Empty the Recycle Bin?"
        subtitle={bin ? `This deletes ${plural(bin.items, "item")} (${bytes(bin.bytes)}) for good.` : "This deletes everything in it for good."} />
      <div className="sheet-body" style={{ paddingTop: 4 }}>
        <p className="small muted">Everything in the Recycle Bin is deleted permanently, including things you moved there yourself. Nothing can be restored after this, not even from History.</p>
      </div>
      <div className="sheet-foot">
        <span className="spacer" />
        <button className="btn secondary" onClick={closeEmpty} disabled={emptying} data-autofocus>Cancel</button>
        <button className="btn destructive" onClick={emptyRecycleBin} disabled={emptying}>
          {emptying ? <Spinner /> : <Trash2 size={14} aria-hidden="true" />}Empty Recycle Bin
        </button>
      </div>
    </Dialog>
  );
}
