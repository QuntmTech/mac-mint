// Apps (ApplicationsView.swift + RemovedAppsView.swift): every installed app with its size,
// the app's own uninstaller, and AppData folders it may have left behind (review only).
import { useMemo, useState } from "react";
import { FolderOpen, FolderSearch, LayoutGrid, Lock, Play, RotateCw, ShieldAlert, Trash2, Users, User } from "lucide-react";
import { call } from "../api/client";
import type { Candidate, InstalledApp } from "../api/types";
import { bytes, errorText, plural, sum } from "../lib/format";
import type { Swatch } from "../lib/pages";
import { invalidate, toggled, useResource, useSelection } from "../state/resource";
import { useStore } from "../state/store";
import { CandidateRow, reveal } from "../components/CandidateRow";
import {
  Banner, Chip, Dialog, EmptyState, ErrorBanner, LoadingState, PageHeader, SearchField, Segmented, SheetHeader, SkeletonRows, Spinner,
} from "../components/ui";

const PALETTE: Swatch[] = ["sky", "indigo", "violet", "pink", "orange", "teal", "iris", "mint", "rose", "amber"];
function swatchFor(name: string): Swatch {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

export function AppIcon({ app, size = 32 }: { app: Pick<InstalledApp, "name" | "icon">; size?: number }) {
  if (app.icon) return <img src={app.icon} alt="" width={size} height={size} style={{ borderRadius: size * 0.22, flex: "none" }} />;
  const letters = app.name.replace(/[^A-Za-z0-9 ]/g, "").split(" ").filter(Boolean).slice(0, 2).map((w) => w[0]).join("").toUpperCase();
  return <span className={`app-icon sw-${swatchFor(app.name)}`} style={{ width: size, height: size, borderRadius: size * 0.26, fontSize: size * 0.36 }} aria-hidden="true">{letters || "?"}</span>;
}

type Sort = "name" | "size" | "date";

export default function Apps() {
  const res = useResource<InstalledApp[]>("apps", () => call("list_apps"));
  const [search, setSearch] = useState("");
  const [sort, setSort] = useState<Sort>("size");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [uninstalled, setUninstalled] = useState<InstalledApp | null>(null);
  const apps = res.data ?? [];
  const q = search.trim().toLowerCase();
  const list = useMemo(() => apps
    .filter((a) => !q || a.name.toLowerCase().includes(q) || (a.publisher ?? "").toLowerCase().includes(q))
    .sort((a, b) => sort === "name" ? a.name.localeCompare(b.name) : sort === "size" ? (b.bytes ?? -1) - (a.bytes ?? -1) : (b.installDate ?? "").localeCompare(a.installDate ?? "")),
  [apps, q, sort]);
  const current = uninstalled && selectedId === uninstalled.id ? uninstalled : apps.find((a) => a.id === selectedId) ?? list[0] ?? null;

  return (
    <div className="page">
      <PageHeader title="Apps" icon={LayoutGrid} swatch="violet" subtitle="Uninstall apps you don't use, then clear what they left behind. You review every change first.">
        <button className="btn area" onClick={() => void res.reload()} disabled={res.loading}><RotateCw size={14} />{res.loading ? "Reading…" : "Refresh"}</button>
      </PageHeader>
      {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't list your apps" />}
      {res.initial && !res.error ? (
        <LoadingState title="Finding your apps…" detail="Reading the list Windows keeps of installed apps, with their sizes." icon={LayoutGrid} swatch="violet" />
      ) : apps.length === 0 && !res.error ? (
        <EmptyState icon={LayoutGrid} swatch="violet" title="No apps found" detail="Windows didn't report any installed apps. Try Refresh." action={{ label: "Refresh", onClick: () => void res.reload() }} />
      ) : apps.length > 0 && (
        <>
          <div className="row wrap" style={{ gap: 10 }}>
            <SearchField value={search} onChange={setSearch} placeholder="Search apps" />
            <Segmented label="Sort by" value={sort} onChange={setSort} options={[{ value: "size", label: "Size" }, { value: "name", label: "Name" }, { value: "date", label: "Installed" }]} />
            <span className="spacer" />
            <span className="caption num">{plural(apps.length, "app")} · {bytes(sum(apps, (a) => a.bytes ?? 0))}</span>
          </div>
          <div className="split">
            <section className="card flush" aria-label="Installed apps">
              <div className="row" style={{ padding: "11px 14px", gap: 8 }}>
                <strong>Installed apps</strong><span className="caption num">{list.length}</span>
              </div>
              <div role="listbox" aria-label="Installed apps" style={{ maxHeight: 560, overflowY: "auto" }}>
                {list.map((a) => (
                  <button key={a.id} type="button" role="option" className="app-row" aria-selected={current?.id === a.id} onClick={() => setSelectedId(a.id)}>
                    <AppIcon app={a} />
                    <span className="col" style={{ flex: 1, gap: 1 }}>
                      <span className="row-title truncate">{a.name}</span>
                      <span className="caption truncate">{a.publisher ?? "Unknown publisher"}{a.version ? ` · ${a.version}` : ""}</span>
                    </span>
                    {a.running && <Chip swatch="amber" icon={Play}>Open</Chip>}
                    <span className="size" style={{ fontSize: 12 }}>{a.bytes != null ? bytes(a.bytes) : "—"}</span>
                  </button>
                ))}
                {list.length === 0 && <p className="caption" style={{ padding: 16 }}>No apps match "{search}".</p>}
              </div>
            </section>
            {current && <AppDetail key={current.id} app={current} uninstalled={uninstalled?.id === current.id}
              onUninstalled={(a) => { setUninstalled(a); setSelectedId(a.id); }} />}
          </div>
        </>
      )}
    </div>
  );
}

function AppDetail({ app, uninstalled, onUninstalled }: { app: InstalledApp; uninstalled: boolean; onUninstalled: (a: InstalledApp) => void }) {
  const store = useStore();
  const [confirming, setConfirming] = useState(false);
  const [working, setWorking] = useState(false);
  const [looked, setLooked] = useState(false);
  const leftovers = useResource<Candidate[]>(looked ? `leftovers:${app.id}` : null, () => call("find_leftovers", { id: app.id }));
  const items = leftovers.data ?? [];
  const [selected, setSelected] = useSelection(`leftovers:${app.id}`, leftovers.data, () => items.filter((c) => c.selected).map((c) => c.id));
  const picked = items.filter((c) => selected.has(c.id));

  const uninstall = async () => {
    setWorking(true);
    try {
      const message = await call("uninstall_app", { id: app.id });
      store.notify(message);
      setConfirming(false);
      onUninstalled(app);
      setLooked(true);
      invalidate(["apps"]);
    } catch (e) {
      store.notify(errorText(e), "warn");
    } finally {
      setWorking(false);
    }
  };

  return (
    <section className="card col" style={{ gap: 16 }} aria-label={app.name}>
      <div className="row" style={{ gap: 14, alignItems: "flex-start" }}>
        <AppIcon app={app} size={52} />
        <div className="col" style={{ flex: 1, gap: 4 }}>
          <h2 style={{ fontSize: 19, letterSpacing: -0.3 }}>{app.name}</h2>
          <span className="small muted">{app.publisher ?? "Unknown publisher"}</span>
          <div className="row wrap" style={{ gap: 6 }}>
            {uninstalled && <Chip swatch="mint">Uninstaller opened</Chip>}
            {app.running && !uninstalled && <Chip swatch="amber" icon={Play}>Open right now</Chip>}
            {app.scope === "allUsers" ? <Chip swatch="slate" icon={Users}>For everyone on this PC</Chip> : <Chip swatch="slate" icon={User}>Just for you</Chip>}
          </div>
        </div>
      </div>
      <div className="facts">
        <Fact k="Version" v={app.version ?? "Not listed"} />
        <Fact k="Size" v={app.bytes != null ? bytes(app.bytes) : "Not reported"} />
        <Fact k="Installed" v={app.installDate ? new Date(app.installDate).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" }) : "Not listed"} />
      </div>
      {app.location && <div className="fact"><div className="k">Location</div><div className="v mono" style={{ fontWeight: 500 }}>{app.location}</div></div>}
      {!app.canUninstall && (
        <Banner tone="info" icon={ShieldAlert}>Windows keeps this app, so it can't be uninstalled from MacMint. You can still look for leftover files.</Banner>
      )}
      <div className="row wrap" style={{ gap: 8 }}>
        {app.canUninstall && !uninstalled && (
          <button className="btn area" disabled={store.busy} onClick={() => store.requireUnlock(() => setConfirming(true))}>
            {store.account && !store.account.unlocked ? <Lock size={13} /> : <Trash2 size={14} />}Uninstall…
          </button>
        )}
        {!looked && <button className="btn secondary" onClick={() => setLooked(true)}><FolderSearch size={14} />Look for Leftovers</button>}
        {app.location && <button className="btn plain" onClick={() => reveal(app.location!)}><FolderOpen size={14} />Show in File Explorer</button>}
      </div>

      {looked && (
        <div className="col" style={{ gap: 10 }}>
          <div className="divider" />
          <div className="row" style={{ alignItems: "baseline" }}>
            <strong style={{ fontSize: 13.5 }}>Leftover files</strong>
            <span className="spacer" />
            {items.length > 0 && <span className="caption num">{plural(items.length, "folder")} · {bytes(sum(items, (c) => c.bytes))}</span>}
          </div>
          <p className="caption">Folders in AppData that look like they belong to {app.name}. They can hold settings or saved work, so check each one.</p>
          {leftovers.error && <ErrorBanner message={leftovers.error} onRetry={() => void leftovers.reload()} />}
          {leftovers.initial && !leftovers.error ? <SkeletonRows rows={2} /> : items.length === 0 && !leftovers.error ? (
            <p className="small muted">No leftover folders found for this app.</p>
          ) : (
            <div className="card flush" style={{ boxShadow: "0 0 0 1px var(--divider)" }}>
              {items.map((c) => <CandidateRow key={c.id} item={c} swatch="violet" selected={selected.has(c.id)} showRisk onToggle={(on) => setSelected(toggled(selected, c.id, on))} />)}
            </div>
          )}
          {items.length > 0 && (
            <div className="row">
              <span className="small muted" style={{ flex: 1 }}>{picked.length ? `${plural(picked.length, "folder")} · ${bytes(sum(picked, (c) => c.bytes))} picked` : "Pick the folders you want to review."}</span>
              <button className="btn commit" disabled={picked.length === 0 || store.busy} onClick={() => store.review("App leftovers", picked.map((c) => c.id))}>Review Leftovers…</button>
            </div>
          )}
        </div>
      )}

      {confirming && (
        <Dialog label={`Uninstall ${app.name}`} onClose={() => setConfirming(false)} size="sm" swatch="violet">
          <SheetHeader icon={Trash2} swatch="violet" eyebrow="Uninstall" title={`Uninstall ${app.name}?`}
            subtitle={`MacMint opens ${app.name}'s own uninstaller. Follow its steps, then come back here to look for leftovers.`} />
          <div className="sheet-body" style={{ paddingTop: 2 }}>
            {app.running && <Banner tone="warn" icon={Play}>{app.name} is open. Save your work first. The uninstaller may ask to close it.</Banner>}
            <p className="small muted">Apps remove themselves, so they don't go to the Recycle Bin. To use it again, you'd install it again.</p>
          </div>
          <div className="sheet-foot">
            <span className="spacer" />
            <button className="btn secondary" onClick={() => setConfirming(false)} data-autofocus>Cancel</button>
            <button className="btn commit" onClick={uninstall} disabled={working}>{working && <Spinner />}Open Uninstaller</button>
          </div>
        </Dialog>
      )}
    </section>
  );
}

function Fact({ k, v }: { k: string; v: string }) {
  return <div className="fact"><div className="k">{k}</div><div className="v truncate" title={v}>{v}</div></div>;
}
