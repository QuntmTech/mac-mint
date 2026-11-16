// Developer (DeveloperView.swift): build output and installed packages per project, plus the
// package caches your tools keep. Each item says how it comes back.
import { useMemo } from "react";
import { Boxes, CloudDownload, FolderGit2, Hammer, Moon, Package, RefreshCw, RotateCw } from "lucide-react";
import { call } from "../api/client";
import type { DeveloperItem, DeveloperScan } from "../api/types";
import { bytes, plural, relative, sum } from "../lib/format";
import { toggled, useResource, useSelection } from "../state/resource";
import { useStore } from "../state/store";
import { CandidateRow } from "../components/CandidateRow";
import { Badge, Checkbox, Chip, EmptyState, ErrorBanner, LoadingState, PageHeader, SelectionBar } from "../components/ui";

const QUIET_DAYS = 30;

export default function Developer() {
  const store = useStore();
  const res = useResource<DeveloperScan>("developer", () => call("scan_developer"));
  const scan = res.data;
  const all = useMemo(() => (scan ? [...scan.items, ...scan.caches] : []), [scan]);
  const [selected, setSelected] = useSelection("developer", scan, () => all.filter((c) => c.selected).map((c) => c.id));
  const projects = useMemo(() => {
    const map = new Map<string, DeveloperItem[]>();
    for (const item of scan?.items ?? []) map.set(item.project, [...(map.get(item.project) ?? []), item]);
    return Array.from(map.values()).sort((a, b) => sum(b, (i) => i.bytes) - sum(a, (i) => i.bytes));
  }, [scan]);
  const picked = all.filter((c) => selected.has(c.id));
  const now = Date.now() / 1000;
  const quiet = projects.filter((p) => (p[0].lastActivity ?? now) < now - QUIET_DAYS * 86400);

  return (
    <>
      <div className="page" style={{ paddingBottom: 18 }}>
        <PageHeader title="Developer" icon={Hammer} swatch="orange" subtitle="Build output, installed packages and download caches. See how each one comes back before you decide.">
          <button className="btn area" onClick={() => void res.reload()} disabled={res.loading}><RotateCw size={14} />{res.loading ? "Scanning…" : "Rescan"}</button>
        </PageHeader>
        {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't look through your projects" />}
        {res.initial && !res.error ? (
          <LoadingState title="Looking through your projects…" detail="Finding node_modules, target, .venv and other folders your build tools can make again." icon={Hammer} swatch="orange" />
        ) : scan && all.length === 0 ? (
          <EmptyState icon={Hammer} swatch="orange" title="No developer clutter found" detail="No build folders or package caches turned up. If your code lives somewhere unusual, it may not have been checked." />
        ) : scan && (
          <>
            <div className="grid-cards">
              <Stat icon={Boxes} label="Build output" value={bytes(sum(scan.items.filter((i) => i.kind === "generatedOutput"), (i) => i.bytes))} detail="Your build makes it again" />
              <Stat icon={Package} label="Installed packages" value={bytes(sum(scan.items.filter((i) => i.kind === "installedDependencies"), (i) => i.bytes))} detail="An install command brings them back" />
              <Stat icon={CloudDownload} label="Package caches" value={bytes(sum(scan.caches, (c) => c.bytes))} detail="Download again when needed" />
              <Stat icon={Moon} label="Quiet projects" value={String(quiet.length)} detail={`Not changed in ${QUIET_DAYS}+ days`} />
            </div>
            <div className="row" style={{ alignItems: "baseline" }}>
              <h2 className="section-title">Projects</h2>
              <span className="spacer" />
              <span className="caption">Quiet projects are picked for you. Active ones stay yours to choose.</span>
            </div>
            {projects.map((items) => <ProjectCard key={items[0].project} items={items} selected={selected} setSelected={setSelected} now={now} />)}
            {scan.caches.length > 0 && (
              <section className="card flush" aria-label="Package caches">
                <div className="list-head">
                  <Badge icon={CloudDownload} swatch="orange" size={30} />
                  <div className="col" style={{ flex: 1, gap: 1 }}>
                    <span style={{ fontSize: 13.5, fontWeight: 700 }}>Package caches</span>
                    <span className="caption">Shared by all your projects. They download again the next time a build needs them.</span>
                  </div>
                  <span className="size">{bytes(sum(scan.caches, (c) => c.bytes))}</span>
                </div>
                {scan.caches.map((c) => (
                  <CandidateRow key={c.id} item={c} swatch="orange" selected={selected.has(c.id)} showRisk={false}
                    extra={<Chip swatch="sky" icon={CloudDownload}>Re-downloads</Chip>} onToggle={(on) => setSelected(toggled(selected, c.id, on))} />
                ))}
              </section>
            )}
            {scan.issues.length > 0 && <p className="caption">Not checked: {scan.issues.map((i) => `${i.path ?? i.area} (${i.message})`).join("; ")}</p>}
          </>
        )}
      </div>
      {scan && all.length > 0 && (
        <div className="sticky-bar">
          <SelectionBar count={picked.length} total={sum(picked, (c) => c.bytes)} onClear={() => setSelected(new Set())}
            onCommit={() => store.review("Developer", picked.map((c) => c.id))} disabled={store.busy}
            message="Nothing is removed yet. Your build tools can make every picked folder again." />
        </div>
      )}
    </>
  );
}

function Stat({ icon, label, value, detail }: { icon: typeof Boxes; label: string; value: string; detail: string }) {
  return (
    <div className="health">
      <div className="row"><Badge icon={icon} swatch="orange" size={22} /><span className="eyebrow">{label}</span></div>
      <span className="value">{value}</span>
      <span className="small muted">{detail}</span>
    </div>
  );
}

function ProjectCard({ items, selected, setSelected, now }: { items: DeveloperItem[]; selected: Set<string>; setSelected: (s: Set<string>) => void; now: number }) {
  const first = items[0];
  const last = first.lastActivity;
  const isQuiet = last != null && last < now - QUIET_DAYS * 86400;
  const chosen = items.filter((i) => selected.has(i.id)).length;
  const state = chosen === 0 ? false : chosen === items.length ? true : "mixed";
  return (
    <section className="card flush" aria-label={first.projectName}>
      <div className="list-head">
        <Checkbox state={state} label={`Select all in ${first.projectName}`}
          onChange={(on) => { const next = new Set(selected); items.forEach((i) => (on ? next.add(i.id) : next.delete(i.id))); setSelected(next); }} />
        <Badge icon={FolderGit2} swatch="orange" size={30} />
        <div className="col" style={{ flex: 1, gap: 1 }}>
          <div className="row" style={{ gap: 8 }}>
            <span style={{ fontSize: 13.5, fontWeight: 700 }}>{first.projectName}</span>
            {isQuiet ? <Chip swatch="slate" icon={Moon}>Quiet</Chip> : <Chip swatch="mint">Active</Chip>}
          </div>
          <span className="caption truncate" title={first.project}>{first.project} · {last ? `changed ${relative(last)}` : "no recent changes recorded"} · {plural(items.length, "folder")}</span>
        </div>
        <span className="size" style={{ minWidth: 74, fontSize: 13.5 }}>{bytes(sum(items, (i) => i.bytes))}</span>
      </div>
      {items.map((i) => (
        <CandidateRow key={i.id} item={i} swatch="orange" selected={selected.has(i.id)} showRisk={i.risk !== "safe"}
          extra={<>
            <Chip swatch="slate">{i.tool}</Chip>
            {i.kind === "generatedOutput" ? <Chip swatch="mint" icon={RefreshCw}>Rebuildable</Chip> : <Chip swatch="sky" icon={CloudDownload}>Re-downloads</Chip>}
          </>}
          onToggle={(on) => setSelected(toggled(selected, i.id, on))} />
      ))}
    </section>
  );
}
