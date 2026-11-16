// History (HistoryView.swift): every move MacMint made, with a receipt. Restore puts items
// back where they were while they're still in the Recycle Bin. Always free.
import { useState } from "react";
import { AlertTriangle, Check, ChevronDown, ChevronRight, FolderOpen, History as HistoryIcon, RotateCcw, Undo2 } from "lucide-react";
import { call } from "../api/client";
import type { HistoryEntry } from "../api/types";
import { bytes, dateTime, errorText, plural, relative } from "../lib/format";
import { invalidate, useResource } from "../state/resource";
import { useStore } from "../state/store";
import { reveal } from "../components/CandidateRow";
import { sourceLook } from "../components/OperationFlow";
import { Badge, Banner, Chip, EmptyState, ErrorBanner, LoadingState, PageHeader, Spinner } from "../components/ui";

export default function History() {
  const res = useResource<HistoryEntry[]>("history", () => call("history"));
  const entries = res.data ?? [];
  const total = entries.reduce((a, e) => a + e.receipts.filter((r) => !r.restored).length, 0);

  return (
    <div className="page">
      <PageHeader title="History" icon={HistoryIcon} swatch="slate" subtitle="Everything MacMint moved, with a receipt. Restore puts items back while they're still in the Recycle Bin.">
        {entries.length > 0 && <Chip swatch="slate">{plural(total, "item")} you can restore</Chip>}
      </PageHeader>
      {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't read History" />}
      {res.initial && !res.error ? (
        <LoadingState title="Reading your receipts…" detail="One moment." icon={HistoryIcon} swatch="slate" rows={3} />
      ) : entries.length === 0 && !res.error ? (
        <EmptyState icon={HistoryIcon} swatch="slate" title="Nothing moved yet" trust="You can restore anything from here while it's in the Recycle Bin."
          detail="When you move items to the Recycle Bin, a receipt appears here. Restore puts them back where they were." />
      ) : (
        <>
          <Banner tone="info" icon={Undo2}>Restore works while items are still in the Recycle Bin. Once it's emptied, they're gone for good.</Banner>
          {entries.map((e, i) => <Entry key={e.id} entry={e} startOpen={i === 0} />)}
        </>
      )}
    </div>
  );
}

function Entry({ entry, startOpen }: { entry: HistoryEntry; startOpen: boolean }) {
  const { notify } = useStore();
  const [open, setOpen] = useState(startOpen);
  const [busy, setBusy] = useState<string | null>(null);
  const look = sourceLook(entry.title);
  const remaining = entry.receipts.filter((r) => !r.restored);

  const restore = async (path: string) => {
    setBusy(path);
    try {
      notify(await call("restore", { entryId: entry.id, originalPath: path }));
      invalidate(["history", "overview", "cleanup", "developer", "largeFiles:", "duplicates", "downloads"]);
    } catch (e) {
      notify(errorText(e), "warn");
    } finally {
      setBusy(null);
    }
  };
  const restoreAll = async () => {
    for (const r of remaining) {
      setBusy(r.originalPath);
      try { await call("restore", { entryId: entry.id, originalPath: r.originalPath }); }
      catch (e) { notify(errorText(e), "warn"); break; }
    }
    setBusy(null);
    notify(`Restored items from "${entry.title}".`);
    invalidate(["history", "overview", "cleanup", "developer", "largeFiles:", "duplicates", "downloads"]);
  };

  return (
    <section className="card flush" aria-label={entry.title}>
      <div className="list-head" style={{ gap: 12 }}>
        <button className="icon-btn" aria-expanded={open} aria-label={open ? "Hide receipts" : "Show receipts"} onClick={() => setOpen(!open)}>
          {open ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
        </button>
        <Badge icon={look.icon} swatch={look.swatch} size={32} />
        <div className="col" style={{ flex: 1, gap: 2 }}>
          <span style={{ fontSize: 13.5, fontWeight: 700 }}>{entry.title}</span>
          <span className="caption" title={dateTime(entry.date)}>{relative(entry.date)} · {dateTime(entry.date)} · {plural(entry.receipts.length, "receipt")}</span>
        </div>
        <span className="size" style={{ fontSize: 13.5 }}>{bytes(entry.bytes)}</span>
        {remaining.length > 1 && (
          <button className="btn secondary sm" onClick={() => void restoreAll()} disabled={!!busy}><RotateCcw size={12} />Restore All</button>
        )}
      </div>
      {open && (
        <>
          {entry.notes && <p className="small muted" style={{ padding: "0 18px 10px 62px" }}>{entry.notes}</p>}
          {entry.uncertain.length > 0 && (
            <div style={{ padding: "0 16px 12px" }}>
              <Banner tone="warn" icon={AlertTriangle}>
                <strong>Needs a look</strong>
                {entry.uncertain.map((u) => <div key={u} className="small muted">{u}</div>)}
              </Banner>
            </div>
          )}
          {entry.receipts.map((r) => (
            <div key={r.originalPath} className="list-row" style={{ minHeight: 46 }}>
              <span style={{ width: 28 }} />
              <div className="col" style={{ flex: 1, gap: 1 }}>
                <span className="row-title truncate">{r.originalPath.split("\\").pop()}</span>
                <span className="mono faint truncate" title={r.originalPath}>{r.originalPath}</span>
              </div>
              <span className="size">{bytes(r.bytes)}</span>
              {r.restored ? (
                <>
                  <Chip swatch="mint" icon={Check}>Restored</Chip>
                  <button className="icon-btn" title="Show in File Explorer" aria-label={`Show ${r.originalPath} in File Explorer`} onClick={() => reveal(r.originalPath)}><FolderOpen size={14} /></button>
                </>
              ) : (
                <button className="btn secondary sm" onClick={() => void restore(r.originalPath)} disabled={!!busy} style={{ minWidth: 86 }}>
                  {busy === r.originalPath ? <Spinner /> : <Undo2 size={12} />}Restore
                </button>
              )}
            </div>
          ))}
        </>
      )}
    </section>
  );
}
