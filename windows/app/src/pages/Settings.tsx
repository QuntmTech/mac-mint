// Settings (SettingsView.swift): appearance, safety, privacy, exclusions, updates, AI,
// account and app details. Safety and privacy stay in your control.
import { useState, type ReactNode } from "react";
import {
  ArrowDownCircle, CircleUser, EyeOff, FolderOpen, Hand, Info, Map as MapIcon, Monitor, Moon, Paintbrush, Plus, RefreshCw, Settings as SettingsIcon,
  ShieldCheck, Sparkles, Sun, X, type LucideIcon,
} from "lucide-react";
import { call } from "../api/client";
import type { AppInfo, Settings as SettingsT, UpdateInfo } from "../api/types";
import { errorText } from "../lib/format";
import type { Swatch } from "../lib/pages";
import { useResource } from "../state/resource";
import { useStore } from "../state/store";
import { Badge, Banner, ErrorBanner, PageHeader, Spinner, Switch } from "../components/ui";
import { AIConsentDialog } from "./Assistant";

export default function Settings() {
  const { settings, saveSettings, account, go, startTour, notify } = useStore();
  const info = useResource<AppInfo>("appInfo", () => call("app_info"));
  const [consent, setConsent] = useState(false);
  if (!settings) return <div className="page"><PageHeader title="Settings" icon={SettingsIcon} swatch="slate" subtitle="Loading…" /></div>;

  return (
    <div className="page">
      <PageHeader title="Settings" icon={SettingsIcon} swatch="slate" subtitle="Appearance, exclusions, updates, account and AI. Safety and privacy stay in your control." />
      <Appearance theme={settings.theme} onChange={(theme) => void saveSettings({ theme })} />
      <div className="two-col" style={{ gridTemplateColumns: "minmax(0,1fr) minmax(0,1fr)" }}>
        <div className="col" style={{ gap: 14 }}>
          <Exclusions settings={settings} save={saveSettings} />
          <Updates auto={settings.checkUpdatesAutomatically} setAuto={(v) => void saveSettings({ checkUpdatesAutomatically: v })} />
          <SettingsCard icon={Sparkles} swatch="iris" title="Ask MacMint" subtitle="Optional AI help · off unless you turn it on">
            <div className="row">
              <span className="small" style={{ flex: 1 }}>Use MacMint AI for answers about your storage</span>
              <Switch on={settings.aiEnabled} label="Use MacMint AI" disabled={!account?.aiAvailable && !settings.aiEnabled}
                onChange={(v) => (v ? setConsent(true) : void saveSettings({ aiEnabled: false }))} />
            </div>
            <p className="caption">{account?.aiAvailable ? "AI only advises. It can't pick, move or remove anything. File contents are never sent." : "Sign in with MacMint Pro to use AI."}</p>
          </SettingsCard>
        </div>
        <div className="col" style={{ gap: 14 }}>
          <SettingsCard icon={ShieldCheck} swatch="mint" title="Safety model">
            <Row k="Removal" v="Recycle Bin first, with a receipt" />
            <Row k="Your personal files" v="Never picked for you" />
            <Row k="Files an app has open" v="Skipped" />
            <Row k="Windows and admin folders" v="Looked at, not changed" />
            <p className="caption" style={{ marginTop: 6 }}>Documents, Desktop, Pictures, Videos and Music are never selected automatically. Large files and duplicates always wait for your choice.</p>
          </SettingsCard>
          <SettingsCard icon={Hand} swatch="graphite" title="Privacy">
            <Row k="Analytics" v="None" />
            <Row k="File contents uploaded" v="Never" />
            <Row k="Network use" v={settings.aiEnabled ? "Account, updates and AI you ask for" : "Account and update checks"} />
            <Row k="History and exclusions" v="Kept on this PC" />
          </SettingsCard>
          <SettingsCard icon={CircleUser} swatch="violet" title="Account" subtitle={account?.signedIn ? account.email ?? "" : "Not signed in"}>
            <p className="small muted">{account?.unlocked ? `MacMint ${account.plan ?? "Pro"} is active on ${account.deviceName}.` : "Looking is free. Moving items to the Recycle Bin needs MacMint Pro."}</p>
            <div><button className="btn secondary sm" onClick={() => go("account")}>Open Account</button></div>
          </SettingsCard>
          <SettingsCard icon={Info} swatch="slate" title="About MacMint">
            {info.error && <ErrorBanner message={info.error} onRetry={() => void info.reload()} />}
            <Row k="Version" v={info.data ? `${info.data.version} (${info.data.build})` : "…"} />
            <Row k="Windows" v={info.data?.platform ?? "…"} />
            <div className="row" style={{ gap: 8, marginTop: 4 }}>
              <span className="mono faint truncate" style={{ flex: 1 }} title={info.data?.dataFolder}>{info.data?.dataFolder ?? ""}</span>
              {info.data && <button className="btn secondary sm" onClick={() => void call("reveal_path", { path: info.data!.dataFolder }).catch((e) => notify(errorText(e), "warn"))}><FolderOpen size={12} />Data Folder</button>}
            </div>
            <div><button className="btn plain" onClick={() => { go("overview"); startTour(0); }}><MapIcon size={14} />Take the Tour Again</button></div>
          </SettingsCard>
        </div>
      </div>
      {consent && <AIConsentDialog onClose={() => setConsent(false)} />}
    </div>
  );
}

export function SettingsCard({ icon, swatch, title, subtitle, children, trailing }: { icon: LucideIcon; swatch: Swatch; title: string; subtitle?: string; children: ReactNode; trailing?: ReactNode }) {
  return (
    <section className="card col" style={{ gap: 10 }} aria-label={title}>
      <div className="row" style={{ gap: 12, marginBottom: 2 }}>
        <Badge icon={icon} swatch={swatch} size={30} />
        <div className="col" style={{ flex: 1, gap: 1 }}>
          <span style={{ fontSize: 14, fontWeight: 700 }}>{title}</span>
          {subtitle && <span className="caption truncate">{subtitle}</span>}
        </div>
        {trailing}
      </div>
      {children}
    </section>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="row" style={{ padding: "7px 0", borderTop: "1px solid var(--divider)", gap: 12 }}>
      <span className="small muted" style={{ flex: 1 }}>{k}</span>
      <span className="small" style={{ fontWeight: 600, textAlign: "right" }}>{v}</span>
    </div>
  );
}

function Appearance({ theme, onChange }: { theme: SettingsT["theme"]; onChange: (t: SettingsT["theme"]) => void }) {
  const options: { value: SettingsT["theme"]; label: string; icon: LucideIcon }[] = [
    { value: "system", label: "System", icon: Monitor }, { value: "light", label: "Light", icon: Sun }, { value: "dark", label: "Dark", icon: Moon },
  ];
  return (
    <SettingsCard icon={Paintbrush} swatch="mint" title="Appearance" subtitle="Make MacMint feel at home on your PC.">
      <div role="radiogroup" aria-label="Appearance" style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: 12 }}>
        {options.map((o) => {
          const active = theme === o.value;
          return (
            <button key={o.value} type="button" role="radio" aria-checked={active} onClick={() => onChange(o.value)}
              style={{ border: 0, padding: 10, borderRadius: 12, textAlign: "left", background: active ? "var(--selection)" : "var(--panel)",
                boxShadow: active ? "inset 0 0 0 2px var(--accent-text)" : "inset 0 0 0 1px var(--border)", display: "flex", flexDirection: "column", gap: 10 }}>
              <Preview kind={o.value} />
              <span className="row" style={{ fontWeight: 500 }}><o.icon size={14} aria-hidden="true" />{o.label}</span>
            </button>
          );
        })}
      </div>
      <p className="caption">{theme === "system" ? "Follows your Windows light or dark setting automatically." : "Applies to every MacMint window. Change it any time."}</p>
    </SettingsCard>
  );
}

function Preview({ kind }: { kind: SettingsT["theme"] }) {
  const pane = (dark: boolean) => (
    <div style={{ flex: 1, background: dark ? "#1c1c1c" : "#f4f4f4", display: "flex", gap: 8, padding: 10 }}>
      <div style={{ width: "22%", display: "flex", flexDirection: "column", gap: 5 }}>
        <span style={{ height: 5, borderRadius: 3, background: "rgba(16,185,129,0.65)" }} />
        <span style={{ height: 4, borderRadius: 3, background: "rgba(128,128,128,0.25)" }} />
        <span style={{ height: 4, borderRadius: 3, background: "rgba(128,128,128,0.25)" }} />
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 6 }}>
        <span style={{ height: 5, width: "45%", borderRadius: 3, background: dark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.35)" }} />
        <span style={{ height: 20, borderRadius: 4, background: "rgba(128,128,128,0.16)" }} />
      </div>
    </div>
  );
  return (
    <div style={{ height: 76, borderRadius: 7, overflow: "hidden", display: "flex", boxShadow: "inset 0 0 0 1px rgba(128,128,128,0.15)" }} aria-hidden="true">
      {kind === "dark" ? pane(true) : pane(false)}
      {kind === "system" && pane(true)}
    </div>
  );
}

function Exclusions({ settings, save }: { settings: SettingsT; save: (p: Partial<SettingsT>) => Promise<void> }) {
  const [draft, setDraft] = useState("");
  const add = () => {
    const path = draft.trim().replace(/[\\/]+$/, "");
    if (!path || settings.exclusions.includes(path)) return;
    void save({ exclusions: [...settings.exclusions, path] });
    setDraft("");
  };
  return (
    <SettingsCard icon={EyeOff} swatch="slate" title="Exclusions" subtitle="Folders MacMint never suggests or moves">
      {settings.exclusions.length === 0 ? <p className="small muted">No exclusions yet. Add a folder, or pick "Exclude from future scans" on any item.</p> : (
        <div className="col" style={{ gap: 6 }}>
          {settings.exclusions.map((path) => (
            <div key={path} className="row" style={{ padding: "6px 6px 6px 10px", borderRadius: 8, background: "var(--panel)" }}>
              <span className="mono truncate" style={{ flex: 1, color: "var(--ink)" }} title={path}>{path}</span>
              <button className="icon-btn" style={{ width: 24, height: 24 }} aria-label={`Remove exclusion ${path}`} title="Remove" onClick={() => void save({ exclusions: settings.exclusions.filter((p) => p !== path) })}><X size={13} /></button>
            </div>
          ))}
        </div>
      )}
      <form className="row" onSubmit={(e) => { e.preventDefault(); add(); }}>
        <input className="field" style={{ height: 30 }} placeholder="C:\Users\Alex\Projects\keep-this" value={draft} onChange={(e) => setDraft(e.target.value)} aria-label="Folder to exclude" />
        <button className="btn secondary" type="submit" disabled={!draft.trim()}><Plus size={13} />Add</button>
      </form>
    </SettingsCard>
  );
}

function Updates({ auto, setAuto }: { auto: boolean; setAuto: (v: boolean) => void }) {
  const { notify } = useStore();
  const res = useResource<UpdateInfo>("updates", () => call("check_updates"));
  const [installing, setInstalling] = useState(false);
  const u = res.data;
  const install = async () => {
    setInstalling(true);
    try { notify(await call("install_update")); } catch (e) { notify(errorText(e), "warn"); } finally { setInstalling(false); }
  };
  return (
    <SettingsCard icon={ArrowDownCircle} swatch="mint" title="Updates" subtitle={u ? `You have ${u.current} (${u.build})` : "Checking…"}
      trailing={<button className="btn secondary sm" onClick={() => void res.reload()} disabled={res.loading}>{res.loading ? <Spinner /> : <RefreshCw size={12} />}Check Now</button>}>
      {res.error && <ErrorBanner message={res.error} onRetry={() => void res.reload()} title="Couldn't check for updates" />}
      {u?.available ? (
        <Banner tone="ok" icon={ArrowDownCircle} action={<button className="btn commit sm" onClick={() => void install()} disabled={installing}>{installing && <Spinner />}Install</button>}>
          <strong>MacMint {u.latest} is ready.</strong>
          {u.notes && <div className="small muted">{u.notes}</div>}
        </Banner>
      ) : u && <p className="small muted">{u.message ?? "You're up to date."}</p>}
      <div className="row">
        <span className="small" style={{ flex: 1 }}>Check for updates automatically</span>
        <Switch on={auto} onChange={setAuto} label="Check for updates automatically" />
      </div>
      <p className="caption">The installer is checked before it runs. MacMint closes while it installs.</p>
    </SettingsCard>
  );
}
