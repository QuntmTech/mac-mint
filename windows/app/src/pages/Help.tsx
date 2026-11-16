// Help (HelpView.swift): short answers to common questions, quick ways to get going, and
// how to reach support.
import { useState } from "react";
import { CircleHelp, ExternalLink, HardDrive, Keyboard, Lock, Map as MapIcon, Radar, Sparkles, Undo2, type LucideIcon } from "lucide-react";
import { call } from "../api/client";
import type { AppInfo } from "../api/types";
import type { Swatch } from "../lib/pages";
import { useResource } from "../state/resource";
import { useStore } from "../state/store";
import { Badge, PageHeader, SearchField } from "../components/ui";

const TOPICS: { id: string; title: string; text: string; icon: LucideIcon; swatch: Swatch }[] = [
  { id: "space", title: "Why didn't my free space go up?", icon: HardDrive, swatch: "indigo",
    text: "Moving files to the Recycle Bin doesn't free their space yet. Windows keeps them so you can get them back. Space comes back after you empty the Recycle Bin." },
  { id: "restore", title: "How do I put something back?", icon: Undo2, swatch: "slate",
    text: "Open History, find the move, and choose Restore. It puts items back where they were, as long as they're still in the Recycle Bin. Restore never overwrites a file." },
  { id: "access", title: "A place couldn't be checked", icon: Lock, swatch: "amber",
    text: "Some folders belong to Windows or need an administrator. MacMint measures them but never changes them. The scan tells you which places it couldn't fully check." },
  { id: "scan", title: "What does Smart Scan look at?", icon: Radar, swatch: "mint",
    text: "Temp files, app caches, logs and crash reports, developer caches, installers and old downloads, project build folders and the Recycle Bin. Storage maps, large files and duplicates run when you open them." },
  { id: "ai", title: "How does AI use my data?", icon: Sparkles, swatch: "iris",
    text: "AI is optional and off until you turn it on. It gets your question and storage categories with sizes, never file contents. It can't pick or remove anything." },
  { id: "keys", title: "Keyboard tips", icon: Keyboard, swatch: "sky",
    text: "Tab moves between controls and Space ticks a checkbox. Esc closes a window or clears a search. In the tour, the arrow keys move between steps." },
];

export default function Help() {
  const { go, startTour, runSmartScan, busy } = useStore();
  const info = useResource<AppInfo>("appInfo", () => call("app_info"));
  const [q, setQ] = useState("");
  const shown = TOPICS.filter((t) => !q || (t.title + " " + t.text).toLowerCase().includes(q.toLowerCase()));

  return (
    <div className="page">
      <PageHeader title="Help" icon={CircleHelp} swatch="mint" subtitle="A little guidance, whenever you need it." />
      <div className="tools">
        <button className="tool" onClick={() => { go("overview"); runSmartScan(); }} disabled={busy}>
          <Badge icon={Radar} swatch="mint" size={30} /><span className="col" style={{ flex: 1 }}><strong style={{ fontSize: 12.5 }}>Run Smart Scan</strong><span className="caption">It only looks</span></span>
        </button>
        <button className="tool" onClick={() => { go("overview"); startTour(0); }}>
          <Badge icon={MapIcon} swatch="iris" size={30} /><span className="col" style={{ flex: 1 }}><strong style={{ fontSize: 12.5 }}>Take the tour</strong><span className="caption">One minute, changes nothing</span></span>
        </button>
        <button className="tool" onClick={() => go("history")}>
          <Badge icon={Undo2} swatch="slate" size={30} /><span className="col" style={{ flex: 1 }}><strong style={{ fontSize: 12.5 }}>Restore something</strong><span className="caption">From History</span></span>
        </button>
      </div>
      <div className="row"><SearchField value={q} onChange={setQ} placeholder="Search help" /></div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(300px, 1fr))", gap: 12 }}>
        {shown.map((t) => (
          <section key={t.id} className="card col" style={{ gap: 8 }}>
            <div className="row" style={{ gap: 10 }}><Badge icon={t.icon} swatch={t.swatch} size={28} /><strong style={{ fontSize: 13.5 }}>{t.title}</strong></div>
            <p className="small muted">{t.text}</p>
          </section>
        ))}
        {shown.length === 0 && <p className="small muted">No topics match. Try another word, or contact support below.</p>}
      </div>
      <section className="card row wrap" style={{ gap: 14 }}>
        <div className="col" style={{ flex: 1, gap: 2, minWidth: 240 }}>
          <strong>Still stuck?</strong>
          <span className="small muted">Write to support and include the version below. No file names or contents are shared unless you add them.</span>
          <span className="caption num">MacMint {info.data ? `${info.data.version} (${info.data.build}) · ${info.data.platform}` : "…"}</span>
        </div>
        <button className="btn secondary" onClick={() => void call("open_url", { url: "https://macmint.co/account" })}><ExternalLink size={13} />Contact Support</button>
      </section>
    </div>
  );
}
