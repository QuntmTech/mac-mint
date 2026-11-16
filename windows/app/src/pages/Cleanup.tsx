// Cleanup (CleanerView.swift + the Mac's Downloads tab): caches, temp files, logs and
// installers grouped with checkboxes and risk chips, plus old downloads and the Recycle Bin.
import { useMemo, useState } from "react";
import { AppWindow, Clock, Download, Layers, Lock, Package, RotateCw, ScrollText, Sparkles, Trash2, type LucideIcon } from "lucide-react";
import { call } from "../api/client";
import type { Candidate, CleanupCategory, CleanupGroup, CleanupScan, ScanReport } from "../api/types";
import { bytes, plural, relative, sum } from "../lib/format";
import type { Swatch } from "../lib/pages";
import { toggled, useResource, useSelection } from "../state/resource";
import { useStore } from "../state/store";
import { CandidateRow } from "../components/CandidateRow";
import {
  Badge, Checkbox, Chip, EmptyState, ErrorBanner, LoadingState, PageHeader, SearchField, Segmented, SelectionBar,
} from "../components/ui";

const LOOK: Record<CleanupCategory, { icon: LucideIcon; swatch: Swatch }> = {
  tempFiles: { icon: Clock, swatch: "sky" },
  appCaches: { icon: Layers, swatch: "indigo" },
  logsAndReports: { icon: ScrollText, swatch: "slate" },
  developerCaches: { icon: Package, swatch: "orange" },
  installers: { icon: AppWindow, swatch: "teal" },
};

type RiskFilter = "all" | "safe" | "review";

export default function Cleanup() {
  const [tab, setTab] = useState<"caches" | "downloads">("caches");
  return (
    tab === "caches" ? <Caches tab={tab} setTab={setTab} /> : <OldDownloads tab={tab} setTab={setTab} />
  );
}

function Tabs({ tab, setTab }: { tab: "caches" | "downloads"; setTab: (t: "caches" | "downloads") => void }) {
  return <Segmented label="Show" value={tab} onChange={setTab} options={[{ value: "caches", label: "Caches & temp files" }, { value: "downloads", label: "Old downloads" }]} />;
}

function Caches({ tab, setTab }: { tab: "caches" | "downloads"; setTab: (t: "caches" | "downloads") => void }) {
  const store = useStore();
  const res = useResource<CleanupScan>("cleanup", () => call("scan_cleanup"));
  const scan = res.data;
  const all = useMemo(() => scan?.groups.flatMap((g) => g.items) ?? [], [scan]);
  const [selected, setSelected] = useSelection("cleanup", scan, () => all.filter((c) => c.selected && c.risk !== "restricted").map((c) => c.id));
  const [search, setSearch] = useState("");
  const [risk, setRisk] = useState<RiskFilter>("all");

  const q = search.trim().toLowerCase();
  const matches = all.filter((c) => !q || c.name.toLowerCase().includes(q) || c.path.toLowerCase().includes(q) || c.group.toLowerCase().includes(q));
  const shown = new Set(matches.filter((c) => risk === "all" || c.risk === risk).map((c) => c.id));
  const groups = (scan?.groups ?? []).map((g) => ({ ...g, items: g.items.filter((c) => shown.has(c.id)) })).filter((g) => g.items.length > 0);
  const picked = all.filter((c) => selected.has(c.id));

  return (
    <>
      <div className="page" style={{ paddingBottom: 18 }}>
        <PageHeader title="Cleanup" icon={Sparkles} swatch="sky" subtitle="Caches, temp files and leftovers that apps make and forget. Keep anything you still need.">
          <button className="btn area" onClick={() => void res.reload()} disabled={res.loading}><RotateCw size={14} />{res.loading ? "Scanning…" : "Rescan"}</button>
        </PageHeader>
        <div className="row wrap" style={{ gap: 10 }}>
          <Tabs tab={tab} setTab={setTab} />
          {scan && <span className="caption">Checked {relative(scan.checkedAt)}</span>}
        </div>
        {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Cleanup couldn't finish looking" />}
        {scan && <RecycleBinCard bytesIn={scan.recycleBin.bytes} items={scan.recycleBin.items} />}
        {scan && all.length > 0 && (
          <div className="row wrap" style={{ gap: 10 }}>
            <SearchField value={search} onChange={setSearch} placeholder="Search cleanup items" />
            <Segmented label="Risk" value={risk} onChange={setRisk} options={[
              { value: "all", label: "All", count: matches.length },
              { value: "safe", label: "Safe", dot: "var(--mint-start)", count: matches.filter((c) => c.risk === "safe").length },
              { value: "review", label: "Review", dot: "var(--amber-start)", count: matches.filter((c) => c.risk === "review").length },
            ]} />
            <span className="spacer" />
            <button className="btn plain" onClick={() => setSelected(new Set(all.filter((c) => c.risk === "safe" && !c.blockedBy).map((c) => c.id)))}>Select safe items</button>
            <button className="btn plain quiet" onClick={() => setSelected(new Set())} disabled={selected.size === 0}>Deselect all</button>
          </div>
        )}
        {res.initial && !res.error ? (
          <LoadingState title="Looking for caches and temp files…" detail="Checking the places Windows and your apps keep temporary files, caches and logs." icon={Sparkles} swatch="sky" />
        ) : scan && all.length === 0 ? (
          <EmptyState icon={Sparkles} swatch="sky" title="Nothing to clean right now" detail="Caches and temp files are small. Check back in a week or two."
            action={{ label: "Scan Again", onClick: () => void res.reload() }} />
        ) : scan && groups.length === 0 ? (
          <EmptyState icon={Sparkles} swatch="sky" title="No matching items" detail="Try a different search or filter." trust={null}
            action={{ label: "Clear Filters", onClick: () => { setSearch(""); setRisk("all"); } }} />
        ) : (
          groups.map((g) => <GroupCard key={g.category} group={g} selected={selected} setSelected={setSelected} />)
        )}
        {scan && scan.issues.length > 0 && (
          <p className="caption">{plural(scan.issues.length, "place")} couldn't be fully checked: {scan.issues.map((i) => i.message).join(" ")}</p>
        )}
      </div>
      {scan && all.length > 0 && (
        <div className="sticky-bar">
          <SelectionBar count={picked.length} total={sum(picked, (c) => c.bytes)} onClear={() => setSelected(new Set())}
            onCommit={() => store.review("Cleanup", picked.map((c) => c.id))} disabled={store.busy}
            commitLabel={store.account && !store.account.unlocked ? "Sign In to Review…" : "Review…"} />
        </div>
      )}
    </>
  );
}

function GroupCard({ group, selected, setSelected }: { group: CleanupGroup; selected: Set<string>; setSelected: (s: Set<string>) => void }) {
  const look = LOOK[group.category];
  const selectable = group.items.filter((c) => c.risk !== "restricted");
  const chosen = selectable.filter((c) => selected.has(c.id)).length;
  const state = chosen === 0 ? false : chosen === selectable.length ? true : "mixed";
  const risks = new Set(group.items.map((c) => c.risk));
  const mixed = risks.size > 1;
  return (
    <section className="card flush" aria-label={group.title}>
      <div className="list-head">
        <Checkbox state={state} disabled={selectable.length === 0} label={`Select all in ${group.title}`}
          onChange={(on) => { const next = new Set(selected); selectable.forEach((c) => (on ? next.add(c.id) : next.delete(c.id))); setSelected(next); }} />
        <Badge icon={look.icon} swatch={look.swatch} size={30} />
        <div className="col" style={{ flex: 1, gap: 1 }}>
          <span style={{ fontSize: 13.5, fontWeight: 700 }}>{group.title}</span>
          <span className="caption truncate">{group.summary} · <span className="num">{plural(group.items.length, "item")}, {chosen} selected</span></span>
        </div>
        {mixed ? <Chip swatch="slate">Mixed</Chip> : group.items[0] && <RiskChipFor c={group.items[0]} />}
        <span className="size" style={{ minWidth: 74, fontSize: 13.5 }}>{bytes(sum(group.items, (c) => c.bytes))}</span>
      </div>
      {group.items.map((c) => (
        <CandidateRow key={c.id} item={c} swatch={look.swatch} selected={selected.has(c.id)} showRisk={mixed}
          onToggle={(on) => setSelected(toggled(selected, c.id, on))} />
      ))}
    </section>
  );
}

function RiskChipFor({ c }: { c: Candidate }) {
  return c.risk === "safe" ? <Chip swatch="mint">Safe</Chip> : c.risk === "review" ? <Chip swatch="amber">Review</Chip> : <Chip swatch="rose">Protected</Chip>;
}

function RecycleBinCard({ bytesIn, items }: { bytesIn: number; items: number }) {
  const { askEmptyRecycleBin, account, busy } = useStore();
  return (
    <div className="card tight row" style={{ gap: 12 }}>
      <Badge icon={Trash2} swatch="graphite" size={32} />
      <div className="col" style={{ flex: 1, gap: 2 }}>
        <strong className="num">{items > 0 ? `Recycle Bin: ${bytes(bytesIn)} in ${plural(items, "item")}` : "The Recycle Bin is empty"}</strong>
        <span className="caption">{items > 0 ? "Things you move to the Recycle Bin still use space until it's emptied." : "Space from items you move comes back after the Recycle Bin is emptied."}</span>
      </div>
      {items > 0 && (
        <button className="btn secondary sm" onClick={askEmptyRecycleBin} disabled={busy}>
          {account && !account.unlocked && <Lock size={11} aria-hidden="true" />}Empty Recycle Bin…
        </button>
      )}
    </div>
  );
}

function OldDownloads({ tab, setTab }: { tab: "caches" | "downloads"; setTab: (t: "caches" | "downloads") => void }) {
  const store = useStore();
  const res = useResource<ScanReport<Candidate[]>>("downloads", () => call("old_downloads"));
  const list = res.data?.value ?? [];
  const [selected, setSelected] = useSelection("downloads", res.data, () => list.filter((c) => c.selected).map((c) => c.id));
  const picked = list.filter((c) => selected.has(c.id));
  return (
    <>
      <div className="page" style={{ paddingBottom: 18 }}>
        <PageHeader title="Cleanup" icon={Sparkles} swatch="sky" subtitle="Downloads you haven't opened in months. Only you know what to keep.">
          <button className="btn area" onClick={() => void res.reload()} disabled={res.loading}><RotateCw size={14} />{res.loading ? "Reading…" : "Rescan"}</button>
        </PageHeader>
        <div className="row wrap" style={{ gap: 10 }}>
          <Tabs tab={tab} setTab={setTab} />
          {list.length > 0 && <span className="caption num">{plural(list.length, "file")} · {bytes(sum(list, (c) => c.bytes))}</span>}
          <span className="spacer" />
          {list.length > 0 && <button className="btn plain" onClick={() => setSelected(new Set(list.map((c) => c.id)))}>Select all</button>}
        </div>
        {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't read your Downloads" />}
        {res.initial && !res.error ? (
          <LoadingState title="Reading your Downloads…" detail="Checking each download's size and when it was last opened." icon={Download} swatch="teal" />
        ) : list.length === 0 && !res.error ? (
          <EmptyState icon={Download} swatch="teal" title="No old downloads" detail="Everything in Downloads was opened recently. Nice and tidy." />
        ) : list.length > 0 && (
          <section className="card flush">
            <div className="table-head"><span style={{ width: 26 }} /><span style={{ flex: 1 }}>Name</span><span style={{ width: 76, textAlign: "right" }}>Size</span><span style={{ width: 28 }} /></div>
            {list.map((c) => <CandidateRow key={c.id} item={c} swatch="teal" selected={selected.has(c.id)} showRisk={false} showModified
              onToggle={(on) => setSelected(toggled(selected, c.id, on))} />)}
          </section>
        )}
      </div>
      {list.length > 0 && (
        <div className="sticky-bar">
          <SelectionBar count={picked.length} total={sum(picked, (c) => c.bytes)} onClear={() => setSelected(new Set())}
            onCommit={() => store.review("Old downloads", picked.map((c) => c.id))} disabled={store.busy} />
        </div>
      )}
    </>
  );
}
