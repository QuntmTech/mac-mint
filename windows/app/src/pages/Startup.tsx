// Startup Apps (StartupItemsView.swift): what starts when you sign in to Windows. Turning
// one off doesn't remove it; items that start for everyone point to Task Manager.
import { useState } from "react";
import { ExternalLink, FolderOpen, Rocket, RotateCw, ShieldCheck, Users, Zap } from "lucide-react";
import { call } from "../api/client";
import type { StartupItem } from "../api/types";
import { errorText, plural } from "../lib/format";
import { update, useResource } from "../state/resource";
import { useStore } from "../state/store";
import { Badge, Banner, Chip, EmptyState, ErrorBanner, LoadingState, PageHeader, Switch } from "../components/ui";
import { AppIcon } from "./Apps";

const WHERE: Record<StartupItem["location"], string> = {
  currentUserRun: "Starts from the registry",
  startupFolder: "Shortcut in your Startup folder",
  allUsersRun: "Starts for everyone (registry)",
  allUsersStartupFolder: "Shortcut in the shared Startup folder",
};

export default function Startup() {
  const { notify } = useStore();
  const res = useResource<StartupItem[]>("startup", () => call("list_startup"));
  const [pending, setPending] = useState<string | null>(null);
  const items = res.data ?? [];
  const mine = items.filter((i) => i.location === "currentUserRun" || i.location === "startupFolder");
  const everyone = items.filter((i) => i.location === "allUsersRun" || i.location === "allUsersStartupFolder");
  const on = items.filter((i) => i.enabled).length;

  const toggle = async (item: StartupItem, enabled: boolean) => {
    setPending(item.id);
    update<StartupItem[]>("startup", (list) => list.map((i) => (i.id === item.id ? { ...i, enabled } : i)));
    try {
      const next = await call("set_startup_enabled", { id: item.id, enabled });
      update<StartupItem[]>("startup", (list) => list.map((i) => (i.id === item.id ? next : i)));
      notify(enabled ? `${item.name} will start when you sign in.` : `${item.name} won't start when you sign in. It's still installed.`);
    } catch (e) {
      update<StartupItem[]>("startup", (list) => list.map((i) => (i.id === item.id ? item : i)));
      notify(errorText(e), "warn");
    } finally {
      setPending(null);
    }
  };
  const taskManager = () => void call("open_task_manager_startup").catch((e) => notify(errorText(e), "warn"));

  return (
    <div className="page">
      <PageHeader title="Startup Apps" icon={Zap} swatch="violet" subtitle="What starts when you sign in to Windows. Turning one off doesn't remove it.">
        {items.length > 0 && <Chip swatch="violet" icon={Rocket}>{on} of {items.length} on</Chip>}
        <button className="btn area" onClick={() => void res.reload()} disabled={res.loading}><RotateCw size={14} />Refresh</button>
      </PageHeader>
      {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't read your startup apps" />}
      {res.initial && !res.error ? (
        <LoadingState title="Reading startup apps…" detail="Checking the places Windows looks when you sign in." icon={Zap} swatch="violet" />
      ) : items.length === 0 && !res.error ? (
        <EmptyState icon={Zap} swatch="violet" title="Nothing starts with Windows" detail="No apps are set to start when you sign in." />
      ) : items.length > 0 && (
        <>
          <Banner tone="info" icon={ShieldCheck} action={<button className="btn secondary sm" onClick={taskManager}><ExternalLink size={12} />Open Task Manager</button>}>
            <strong>Fewer startup apps, faster sign-in.</strong> <span className="muted">Turn off ones you don't need right away. They still open when you start them yourself.</span>
          </Banner>
          <Group title="Just for you" detail="You can turn these on or off here." items={mine} pending={pending} onToggle={toggle} onTaskManager={taskManager} />
          {everyone.length > 0 && (
            <Group title="For everyone on this PC" detail="Changing these needs an administrator. Use Task Manager → Startup apps." items={everyone} pending={pending} onToggle={toggle} onTaskManager={taskManager} />
          )}
        </>
      )}
    </div>
  );
}

function Group({ title, detail, items, pending, onToggle, onTaskManager }: {
  title: string; detail: string; items: StartupItem[]; pending: string | null; onToggle: (i: StartupItem, on: boolean) => void; onTaskManager: () => void;
}) {
  return (
    <section className="card flush" aria-label={title}>
      <div className="list-head">
        <Badge icon={title.startsWith("For everyone") ? Users : Zap} swatch="violet" size={30} />
        <div className="col" style={{ flex: 1, gap: 1 }}>
          <span style={{ fontSize: 13.5, fontWeight: 700 }}>{title}</span>
          <span className="caption">{detail} · {plural(items.length, "item")}, {items.filter((i) => i.enabled).length} on</span>
        </div>
      </div>
      {items.map((item) => (
        <div key={item.id} className="list-row">
          <AppIcon app={{ name: item.name, icon: null }} size={30} />
          <div className="col" style={{ flex: 1, gap: 2 }}>
            <div className="row" style={{ gap: 8 }}>
              <span className="row-title truncate">{item.name}</span>
              {!item.enabled && <Chip swatch="slate">Off</Chip>}
            </div>
            <span className="caption truncate">{item.publisher ?? "Unknown publisher"} · {WHERE[item.location]}</span>
            <span className="mono faint truncate" title={item.command}>{item.command}</span>
          </div>
          <button className="icon-btn" title="Show in File Explorer" aria-label={`Show ${item.name} in File Explorer`}
            onClick={() => void call("reveal_path", { path: item.command.replace(/^"([^"]+)".*$/, "$1").split(" /")[0].split(" -")[0] }).catch(() => undefined)}><FolderOpen size={14} /></button>
          {item.canToggle ? (
            <Switch on={item.enabled} disabled={pending === item.id} label={`Start ${item.name} when you sign in`} onChange={(v) => onToggle(item, v)} />
          ) : (
            <button className="btn secondary sm" onClick={onTaskManager} title="Needs an administrator">Task Manager</button>
          )}
        </div>
      ))}
    </section>
  );
}
