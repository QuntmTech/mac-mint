// Duplicates (DuplicatesView.swift): exact copies, matched byte for byte. One copy in each
// group is always kept; you choose which.
import { useState } from "react";
import { BadgeCheck, Copy, FolderOpen, RotateCw } from "lucide-react";
import { call } from "../api/client";
import type { DuplicateGroup, ScanReport } from "../api/types";
import { bytes, plural, relative, sum } from "../lib/format";
import { toggled, useResource, useSelection } from "../state/resource";
import { useStore } from "../state/store";
import { iconForFile, reveal } from "../components/CandidateRow";
import { Checkbox, Chip, EmptyState, ErrorBanner, LoadingState, PageHeader, SelectionBar, TileIcon } from "../components/ui";

const keepers = new Map<string, string>();

export default function Duplicates() {
  const store = useStore();
  const res = useResource<ScanReport<DuplicateGroup[]>>("duplicates", () => call("find_duplicates"));
  const groups = res.data?.value ?? [];
  const [selected, setSelected] = useSelection("duplicates", res.data, () => []);
  const [, setVersion] = useState(0);
  const keeperOf = (g: DuplicateGroup) => keepers.get(g.id) ?? g.files[0].id;
  const extra = (g: DuplicateGroup) => sum(g.files.slice(1), (f) => f.bytes);
  const all = groups.flatMap((g) => g.files);
  const picked = all.filter((f) => selected.has(f.id));
  const selectAllCopies = () => setSelected(new Set(groups.flatMap((g) => g.files.filter((f) => f.id !== keeperOf(g)).map((f) => f.id))));

  return (
    <>
      <div className="page" style={{ paddingBottom: 18 }}>
        <PageHeader title="Duplicates" icon={Copy} swatch="indigo" subtitle="Exact copies, matched byte for byte. Choose which copy to keep, then review the rest.">
          <button className="btn area" onClick={() => void res.reload()} disabled={res.loading}><RotateCw size={14} />{res.loading ? "Comparing…" : "Compare Again"}</button>
        </PageHeader>
        {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't compare your files" />}
        {res.initial && !res.error ? (
          <LoadingState title="Comparing files…" detail="Matching files by size first, then by their contents. Big folders can take a few minutes." icon={Copy} swatch="indigo" />
        ) : groups.length === 0 && !res.error ? (
          <EmptyState icon={Copy} swatch="indigo" title="No duplicates found" detail="Every file checked is one of a kind." />
        ) : groups.length > 0 && (
          <>
            <div className="card tight row wrap" style={{ gap: 14 }}>
              <div className="col" style={{ flex: 1, gap: 2, minWidth: 220 }}>
                <strong className="num">{plural(groups.length, "set")} of copies · {bytes(sum(groups, extra))} could come back</strong>
                <span className="caption">The copy marked Keep always stays. Nothing is picked until you choose.</span>
              </div>
              <button className="btn secondary" onClick={selectAllCopies}>Select All Extra Copies</button>
            </div>
            {groups.map((g) => {
              const keep = keeperOf(g);
              const first = g.files[0];
              const copies = g.files.filter((f) => f.id !== keep);
              const chosen = copies.filter((f) => selected.has(f.id)).length;
              return (
                <section key={g.id} className="card flush" aria-label={first.name}>
                  <div className="list-head">
                    <Checkbox state={chosen === 0 ? false : chosen === copies.length ? true : "mixed"} label={`Select extra copies of ${first.name}`}
                      onChange={(on) => { const next = new Set(selected); copies.forEach((f) => (on ? next.add(f.id) : next.delete(f.id))); setSelected(next); }} />
                    <TileIcon icon={iconForFile(first.name)} swatch="indigo" />
                    <div className="col" style={{ flex: 1, gap: 1 }}>
                      <span style={{ fontSize: 13.5, fontWeight: 700 }} className="truncate">{first.name}</span>
                      <span className="caption num">{plural(g.files.length, "copy", "copies")} · {bytes(first.bytes)} each</span>
                    </div>
                    <Chip swatch="indigo">{bytes(extra(g))} could come back</Chip>
                  </div>
                  {g.files.map((f) => {
                    const isKeeper = f.id === keep;
                    return (
                      <div key={f.id} className={`list-row ${selected.has(f.id) ? "selected" : ""}`}>
                        <Checkbox state={!isKeeper && selected.has(f.id)} disabled={isKeeper} label={isKeeper ? `${f.path} is kept` : `Select ${f.path}`}
                          onChange={(on) => setSelected(toggled(selected, f.id, on))} />
                        <div className="col" style={{ flex: 1, gap: 2 }}>
                          <span className="mono truncate" style={{ fontSize: 12, color: "var(--ink)" }} title={f.path}>{f.path}</span>
                          <span className="caption">{f.modified ? `Changed ${relative(f.modified)}` : "Change date unknown"}</span>
                        </div>
                        {isKeeper ? <Chip swatch="mint" icon={BadgeCheck}>Keep</Chip>
                          : <button className="btn plain sm" onClick={() => { keepers.set(g.id, f.id); setSelected(toggled(selected, f.id, false)); setVersion((v) => v + 1); }}>Keep this one</button>}
                        <button className="icon-btn" title="Show in File Explorer" aria-label={`Show ${f.path} in File Explorer`} onClick={() => reveal(f.path)}><FolderOpen size={14} /></button>
                      </div>
                    );
                  })}
                </section>
              );
            })}
          </>
        )}
      </div>
      {groups.length > 0 && (
        <div className="sticky-bar">
          <SelectionBar count={picked.length} total={sum(picked, (c) => c.bytes)} onClear={() => setSelected(new Set())}
            onCommit={() => store.review("Duplicates", picked.map((c) => c.id))} disabled={store.busy}
            message="The copy marked Keep always stays. You check everything once more before it moves." />
        </div>
      )}
    </>
  );
}
