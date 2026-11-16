// Storage (StorageExplorerView.swift): a folder map you can click into, with a sized list
// underneath. Mapping only reads; picking things to remove happens on other pages.
import { useMemo, useState } from "react";
import { ArrowUp, ChartPie, ChevronRight, Eye, File, Folder, FolderOpen, HardDrive, Lock } from "lucide-react";
import { call } from "../api/client";
import type { FolderUsage, StorageBreakdown } from "../api/types";
import { bytes, percent, plural } from "../lib/format";
import type { Swatch } from "../lib/pages";
import { useResource } from "../state/resource";
import { useStore } from "../state/store";
import { reveal } from "../components/CandidateRow";
import { Chip, ErrorBanner, LoadingState, MoreMenu, PageHeader, SkeletonBlock, Spinner, sw } from "../components/ui";

const COLORS: Swatch[] = ["indigo", "violet", "sky", "iris", "teal", "pink", "orange", "amber", "mint", "rose"];
const MAX_CELLS = 14;

interface Cell { item: FolderUsage | null; label: string; value: number; x: number; y: number; w: number; h: number; color: Swatch }

/** Squarified treemap: rows of blocks kept as close to square as possible. */
function squarify(values: { item: FolderUsage | null; label: string; value: number; color: Swatch }[], W: number, H: number): Cell[] {
  const total = values.reduce((a, v) => a + v.value, 0);
  if (total <= 0) return [];
  const scale = (W * H) / total;
  const items = values.map((v) => ({ ...v, area: v.value * scale }));
  const out: Cell[] = [];
  let x = 0, y = 0, w = W, h = H;
  let row: typeof items = [];
  const worst = (r: typeof items, side: number) => {
    const s = r.reduce((a, v) => a + v.area, 0);
    const max = Math.max(...r.map((v) => v.area)), min = Math.min(...r.map((v) => v.area));
    return Math.max((side * side * max) / (s * s), (s * s) / (side * side * min));
  };
  const place = (r: typeof items) => {
    const s = r.reduce((a, v) => a + v.area, 0);
    if (w >= h) {
      const t = s / h;
      let oy = y;
      for (const v of r) { const hh = v.area / t; out.push({ ...v, x, y: oy, w: t, h: hh }); oy += hh; }
      x += t; w -= t;
    } else {
      const t = s / w;
      let ox = x;
      for (const v of r) { const ww = v.area / t; out.push({ ...v, x: ox, y, w: ww, h: t }); ox += ww; }
      y += t; h -= t;
    }
  };
  for (const v of items) {
    const side = Math.min(w, h);
    if (row.length === 0 || worst([...row, v], side) <= worst(row, side)) row.push(v);
    else { place(row); row = [v]; }
  }
  if (row.length) place(row);
  return out;
}

export default function Storage() {
  const { overview } = useStore();
  const disks = overview.data?.disks ?? [];
  const [path, setPath] = useState<string | null>(null);
  const res = useResource<StorageBreakdown>(`storage:${path ?? ""}`, () => call("storage_breakdown", { path }));
  const data = res.data;
  const root = data?.path ?? path ?? "C:\\";
  const drive = root.slice(0, 3);
  const parts = root.replace(/\\$/, "").split("\\").filter(Boolean);
  const crumbs = parts.map((p, i) => ({ label: i === 0 ? p : p, path: i === 0 ? p + "\\" : parts.slice(0, i + 1).join("\\") }));
  const parent = crumbs.length > 1 ? crumbs[crumbs.length - 2].path : null;

  const cells = useMemo(() => {
    if (!data) return [];
    const kids = data.children.filter((c) => c.bytes > 0);
    const top: { item: FolderUsage | null; label: string; value: number; color: Swatch }[] = kids.slice(0, MAX_CELLS).map((c, i) => ({ item: c, label: c.name, value: c.bytes, color: COLORS[i % COLORS.length] }));
    const rest = kids.slice(MAX_CELLS).reduce((a, c) => a + c.bytes, 0);
    if (rest > 0) top.push({ item: null, label: `${kids.length - MAX_CELLS} more`, value: rest, color: "slate" });
    return squarify(top, 1000, 300);
  }, [data]);

  const open = (c: FolderUsage) => { if (c.isDir) setPath(c.path); };
  const unreadable = data?.children.reduce((a, c) => a + c.unreadable, 0) ?? 0;

  return (
    <div className="page">
      <PageHeader title="Storage" icon={ChartPie} swatch="indigo" subtitle="See what takes up room, folder by folder. Click a block to open it.">
        <span className="pill"><Eye size={13} aria-hidden="true" />Looking only</span>
      </PageHeader>
      {disks.length > 1 && (
        <div className="row wrap" style={{ gap: 8 }} role="group" aria-label="Drives">
          {disks.map((d) => {
            const active = drive.toUpperCase() === d.mount.slice(0, 3).toUpperCase();
            return (
              <button key={d.mount} type="button" className={`tool ${active ? "" : ""}`} aria-pressed={active}
                style={{ flex: "0 1 260px", boxShadow: active ? "0 0 0 2px var(--indigo-text)" : undefined }} onClick={() => setPath(d.mount)}>
                <span className="tile-icon sw-indigo" style={{ width: 30, height: 30 }} aria-hidden="true"><HardDrive size={15} /></span>
                <span className="col" style={{ flex: 1, gap: 3 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 600 }}>{d.name} ({d.mount.replace(/\\$/, "")})</span>
                  <span className={`bar ${sw("indigo")}`} style={{ height: 4 }}><span style={{ width: percent((d.total - d.free) / d.total) }} /></span>
                  <span className="caption num">{bytes(d.free)} free of {bytes(d.total)}</span>
                </span>
              </button>
            );
          })}
        </div>
      )}
      <div className="row wrap" style={{ gap: 8 }}>
        <button className="icon-btn" onClick={() => parent && setPath(parent)} disabled={!parent} aria-label="Up one folder" title="Up one folder"><ArrowUp size={15} /></button>
        <nav className="breadcrumbs" aria-label="Folder path">
          {crumbs.map((c, i) => (
            <span key={c.path} className="row" style={{ gap: 2 }}>
              {i > 0 && <ChevronRight size={13} className="faint" aria-hidden="true" />}
              <button type="button" aria-current={i === crumbs.length - 1 ? "location" : undefined} onClick={() => setPath(c.path)}>{c.label}</button>
            </span>
          ))}
        </nav>
        {res.loading && data && <Spinner color="var(--indigo-text)" />}
        <span className="spacer" />
        {data && <span className="small muted num"><strong style={{ color: "var(--ink)" }}>{bytes(data.bytes)}</strong> in {plural(data.children.length, "item")}</span>}
        {unreadable > 0 && <Chip swatch="amber" icon={Lock}>{plural(unreadable, "folder")} couldn't be read</Chip>}
      </div>
      {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't map this folder" />}
      {!data && !res.error ? (
        <>
          <SkeletonBlock height={300} radius={14} />
          <LoadingState title={`Mapping ${root}…`} detail="Measuring each folder so you can see what takes up space. Nothing is opened or changed." icon={ChartPie} swatch="indigo" rows={4} />
        </>
      ) : data && (
        <>
          <div className="treemap" role="group" aria-label={`Folder map of ${root}`} style={{ opacity: res.loading ? 0.6 : 1 }}>
            {cells.map((c) => {
              const big = c.w > 95 && c.h > 44;
              return (
                <button key={c.item?.path ?? "rest"} type="button" className={`tm-cell ${sw(c.color)} ${c.item && !c.item.isDir ? "file" : ""}`}
                  style={{ left: `${c.x / 10}%`, top: `${(c.y / 300) * 100}%`, width: `${c.w / 10}%`, height: `${(c.h / 300) * 100}%` }}
                  disabled={!c.item?.isDir} onClick={() => c.item && open(c.item)}
                  title={`${c.label}: ${bytes(c.value)}${c.item?.isDir ? " · click to open" : ""}`} aria-label={`${c.label}, ${bytes(c.value)}`}>
                  {big && <><span className="tm-name">{c.label}</span><span className="tm-size">{bytes(c.value)}</span></>}
                </button>
              );
            })}
          </div>
          <section className="card flush" aria-label="Folder contents">
            <div className="table-head">
              <span style={{ flex: 1 }}>Name</span>
              <span style={{ width: 170 }} className="hide-narrow">Share of {parts[parts.length - 1] ?? root}</span>
              <span style={{ width: 80, textAlign: "right" }}>Size</span>
              <span style={{ width: 28 }} />
            </div>
            {data.children.map((c, i) => (
              <div key={c.path} className="list-row" style={{ minHeight: 44 }}>
                <span className={`tile-icon ${sw(i < MAX_CELLS ? COLORS[i % COLORS.length] : "slate")}`} style={{ width: 28, height: 28 }} aria-hidden="true">
                  {c.isDir ? <Folder size={14} /> : <File size={14} />}
                </span>
                <div className="col" style={{ flex: 1, gap: 1 }}>
                  {c.isDir
                    ? <button type="button" className="row-title truncate" style={{ border: 0, background: "transparent", padding: 0, textAlign: "left" }} onClick={() => open(c)}>{c.name}</button>
                    : <span className="row-title truncate">{c.name}</span>}
                  <span className="caption">{c.isDir ? plural(c.files, "file") : "File"}{c.unreadable ? ` · ${plural(c.unreadable, "folder")} couldn't be read` : ""}</span>
                </div>
                <span className="hide-narrow" style={{ width: 170 }}>
                  <span className="row" style={{ gap: 8 }}>
                    <span className={`bar ${sw(i < MAX_CELLS ? COLORS[i % COLORS.length] : "slate")}`} style={{ flex: 1 }}><span style={{ width: `${data.bytes ? (c.bytes / data.bytes) * 100 : 0}%` }} /></span>
                    <span className="caption num" style={{ width: 34, textAlign: "right" }}>{data.bytes ? percent(c.bytes / data.bytes) : "—"}</span>
                  </span>
                </span>
                <span className="size" style={{ width: 80 }}>{bytes(c.bytes)}</span>
                <MoreMenu label={`More actions for ${c.name}`} items={[
                  ...(c.isDir ? [{ label: "Open here", icon: Folder, onClick: () => open(c) }] : []),
                  { label: "Show in File Explorer", icon: FolderOpen, onClick: () => reveal(c.path) },
                ]} />
              </div>
            ))}
          </section>
          <p className="caption">Sizes are what each folder uses on disk. To clear space, use Cleanup, Large Files or Duplicates, where you review everything first.</p>
        </>
      )}
    </div>
  );
}
