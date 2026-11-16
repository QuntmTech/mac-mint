// One reviewable item: checkbox, owner icon, name, path, why, risk, size and a ••• menu.
import type { ReactNode } from "react";
import {
  AlertTriangle, AppWindow, Clock, Code2, Disc3, Download, File, FileArchive, FileText, FileVideo, FolderOpen, Gamepad2, Globe, Image,
  MessageCircle, Monitor, Music, Package, ScrollText, Users, EyeOff, type LucideIcon,
} from "lucide-react";
import { call } from "../api/client";
import type { Candidate } from "../api/types";
import { bytes, relative } from "../lib/format";
import type { Swatch } from "../lib/pages";
import { invalidate } from "../state/resource";
import { useStore } from "../state/store";
import { Checkbox, Chip, MoreMenu, RiskChip, TileIcon } from "./ui";

const GROUP_ICONS: Record<string, LucideIcon> = {
  Chrome: Globe, Edge: Globe, Discord: MessageCircle, Spotify: Music, "VS Code": Code2, Teams: Users, npm: Package, pip: Package,
  NuGet: Package, Cargo: Package, Gradle: Package, Yarn: Package, Windows: Monitor, Steam: Gamepad2, DirectX: Gamepad2, Temp: Clock,
  "File Explorer": FolderOpen, Downloads: Download, Apps: AppWindow,
};

export function iconForFile(name: string): LucideIcon {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  if (["mp4", "mkv", "mov", "avi", "webm"].includes(ext)) return FileVideo;
  if (["zip", "7z", "rar", "tar", "gz"].includes(ext)) return FileArchive;
  if (["iso", "vdi", "vhdx", "vmdk", "img"].includes(ext)) return Disc3;
  if (["jpg", "jpeg", "png", "nef", "heic", "gif", "psd", "raw"].includes(ext)) return Image;
  if (["mp3", "wav", "flac", "m4a"].includes(ext)) return Music;
  if (["exe", "msi"].includes(ext)) return Package;
  if (["pdf", "docx", "doc", "txt", "csv", "xlsx"].includes(ext)) return FileText;
  if (["log"].includes(ext)) return ScrollText;
  return File;
}

export function iconFor(c: Candidate): LucideIcon {
  return GROUP_ICONS[c.group] ?? (c.name.includes(".") ? iconForFile(c.name) : FolderOpen);
}

export function reveal(path: string) { void call("reveal_path", { path }).catch(() => undefined); }

/** Adds a path to Settings → Exclusions; the page reloads without it. */
export function useExclude() {
  const { settings, saveSettings, notify } = useStore();
  return async (path: string) => {
    if (!settings || settings.exclusions.includes(path)) return;
    await saveSettings({ exclusions: [...settings.exclusions, path] });
    notify("Excluded from future scans. Change this in Settings.");
    invalidate(["cleanup", "downloads", "developer", "largeFiles:", "duplicates", "overview"]);
  };
}

export function CandidateRow({ item, selected, onToggle, swatch, showRisk = true, extra, showModified }: {
  item: Candidate; selected: boolean; onToggle: (on: boolean) => void; swatch: Swatch; showRisk?: boolean; extra?: ReactNode; showModified?: boolean;
}) {
  const exclude = useExclude();
  const restricted = item.risk === "restricted";
  return (
    <div className={`list-row ${selected ? "selected" : ""}`}>
      <Checkbox state={selected} onChange={onToggle} disabled={restricted} label={`Select ${item.name}, ${bytes(item.bytes)}`} />
      <TileIcon icon={iconFor(item)} swatch={item.blockedBy ? "amber" : swatch} />
      <div className="col" style={{ flex: 1, gap: 2 }}>
        <div className="row" style={{ gap: 8, alignItems: "baseline" }}>
          <span className="row-title truncate" style={{ flex: "0 1 auto" }} title={item.name}>{item.name}</span>
          <span className="mono faint truncate" title={item.path} style={{ flex: "1 1 0" }}>{item.path}</span>
        </div>
        {item.blockedBy
          ? <span className="row-sub truncate" style={{ color: "var(--warning)" }}><AlertTriangle size={11} style={{ verticalAlign: -1, marginRight: 4 }} aria-hidden="true" />{item.blockedBy}</span>
          : <span className="row-sub truncate" title={item.reason}>{item.reason}</span>}
        {showModified && item.modified && <span className="caption">Changed {relative(item.modified)} · {item.detail}</span>}
      </div>
      {extra}
      {item.blockedBy && <Chip swatch="amber" icon={AlertTriangle}>In use</Chip>}
      {showRisk && <RiskChip risk={item.risk} />}
      <span className="size" style={{ width: 76 }}>{bytes(item.bytes)}</span>
      <MoreMenu label={`More actions for ${item.name}`} items={[
        { label: "Show in File Explorer", icon: FolderOpen, onClick: () => reveal(item.path) },
        { label: "Exclude from future scans", icon: EyeOff, onClick: () => void exclude(item.path) },
      ]} />
    </div>
  );
}
