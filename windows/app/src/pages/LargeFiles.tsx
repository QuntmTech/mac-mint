// Large Files (LargeFilesView.swift): the biggest single files, wherever they are. Nothing is
// picked for you; what stays is always your decision.
import { useState } from "react";
import { FileBox, RotateCw } from "lucide-react";
import { call } from "../api/client";
import type { Candidate, ScanReport } from "../api/types";
import { bytes, plural, sum } from "../lib/format";
import { toggled, useResource, useSelection } from "../state/resource";
import { useStore } from "../state/store";
import { CandidateRow } from "../components/CandidateRow";
import { Chip, EmptyState, ErrorBanner, LoadingState, PageHeader, Segmented, SelectionBar } from "../components/ui";

const MB = 1024 ** 2;
const SIZES = [100 * MB, 500 * MB, 1024 * MB];

export default function LargeFiles() {
  const store = useStore();
  const [min, setMin] = useState(SIZES[0]);
  const res = useResource<ScanReport<Candidate[]>>(`largeFiles:${min}`, () => call("large_files", { minBytes: min }));
  const list = res.data?.value ?? [];
  const [selected, setSelected] = useSelection("largeFiles", res.data, () => list.filter((c) => c.selected).map((c) => c.id));
  const picked = list.filter((c) => selected.has(c.id));
  const issues = res.data?.issues ?? [];

  return (
    <>
      <div className="page" style={{ paddingBottom: 18 }}>
        <PageHeader title="Large Files" icon={FileBox} swatch="indigo" subtitle="The biggest single files on your PC, wherever they are. What stays is always your decision.">
          {list.length > 0 && <Chip swatch="indigo">{plural(list.length, "file")} · {bytes(sum(list, (c) => c.bytes))}</Chip>}
          <button className="btn area" onClick={() => void res.reload()} disabled={res.loading}><RotateCw size={14} />{res.loading ? "Looking…" : "Look Again"}</button>
        </PageHeader>
        <div className="row wrap" style={{ gap: 10 }}>
          <span className="small muted">Show files bigger than</span>
          <Segmented label="Smallest size" value={min} onChange={setMin} options={SIZES.map((s) => ({ value: s, label: bytes(s) }))} />
          <span className="spacer" />
          {list.length > 0 && <button className="btn plain quiet" onClick={() => setSelected(new Set())} disabled={selected.size === 0}>Deselect all</button>}
        </div>
        {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Large Files couldn't finish looking" />}
        {res.initial && !res.error ? (
          <LoadingState title="Looking for large files…" detail="Going through your folders for single files bigger than the size you picked. Nothing is opened." icon={FileBox} swatch="indigo" />
        ) : list.length === 0 && !res.error ? (
          <EmptyState icon={FileBox} swatch="indigo" title="No files this big" detail={`Nothing bigger than ${bytes(min)} turned up. Try a smaller size.`} />
        ) : list.length > 0 && (
          <section className="card flush" aria-label="Large files">
            <div className="table-head"><span style={{ width: 26 }} /><span style={{ flex: 1 }}>Name</span><span style={{ width: 76, textAlign: "right" }}>Size</span><span style={{ width: 28 }} /></div>
            {list.map((c) => <CandidateRow key={c.id} item={c} swatch="indigo" selected={selected.has(c.id)} showRisk={false} showModified
              onToggle={(on) => setSelected(toggled(selected, c.id, on))} />)}
          </section>
        )}
        {issues.length > 0 && <p className="caption">{plural(issues.length, "folder")} couldn't be checked: {issues.map((i) => i.message).join(" ")}</p>}
      </div>
      {list.length > 0 && (
        <div className="sticky-bar">
          <SelectionBar count={picked.length} total={sum(picked, (c) => c.bytes)} onClear={() => setSelected(new Set())}
            onCommit={() => store.review("Large Files", picked.map((c) => c.id))} disabled={store.busy} />
        </div>
      )}
    </>
  );
}
