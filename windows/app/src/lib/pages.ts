// Where everything lives: each page's name, icon, color and the sidebar area it belongs to.
import {
  ChartPie, CircleHelp, CircleUser, Copy, FileBox, Gauge, Hammer, History, LayoutGrid, Leaf, Radar, Settings,
  Sparkles, WandSparkles, Zap, type LucideIcon,
} from "lucide-react";
import type { Page } from "../api/types";

export type Swatch = "mint" | "sky" | "indigo" | "violet" | "pink" | "orange" | "amber" | "slate" | "graphite" | "iris" | "teal" | "rose";

export interface PageMeta {
  title: string;
  icon: LucideIcon;
  swatch: Swatch;
  /** The sidebar area the page sits under. */
  area: Page;
}

export const PAGES: Record<Page, PageMeta> = {
  overview: { title: "Overview", icon: Leaf, swatch: "mint", area: "overview" },
  smartScan: { title: "Smart Scan", icon: Radar, swatch: "mint", area: "overview" },
  performance: { title: "Performance", icon: Gauge, swatch: "sky", area: "overview" },
  cleanup: { title: "Cleanup", icon: Sparkles, swatch: "sky", area: "cleanup" },
  storage: { title: "Storage", icon: ChartPie, swatch: "indigo", area: "storage" },
  largeFiles: { title: "Large Files", icon: FileBox, swatch: "indigo", area: "storage" },
  duplicates: { title: "Duplicates", icon: Copy, swatch: "indigo", area: "storage" },
  apps: { title: "Apps", icon: LayoutGrid, swatch: "violet", area: "apps" },
  startup: { title: "Startup Apps", icon: Zap, swatch: "violet", area: "apps" },
  developer: { title: "Developer", icon: Hammer, swatch: "orange", area: "developer" },
  assistant: { title: "Ask MacMint", icon: WandSparkles, swatch: "iris", area: "assistant" },
  history: { title: "History", icon: History, swatch: "slate", area: "history" },
  settings: { title: "Settings", icon: Settings, swatch: "slate", area: "settings" },
  account: { title: "Account", icon: CircleUser, swatch: "violet", area: "account" },
  help: { title: "Help", icon: CircleHelp, swatch: "mint", area: "help" },
};

/** The sidebar's areas, in order. */
export const AREAS: Page[] = ["overview", "cleanup", "storage", "apps", "developer", "assistant", "history"];

/** Tabs shown in the toolbar for an area. */
export const TABS: Partial<Record<Page, Page[]>> = {
  overview: ["overview", "smartScan", "performance"],
  storage: ["storage", "largeFiles", "duplicates"],
  apps: ["apps", "startup"],
};

/** What the tour and onboarding say beside each area. */
export const AREA_BLURB: Partial<Record<Page, string>> = {
  overview: "Your PC at a glance",
  cleanup: "Caches, temp files and old downloads",
  storage: "What takes up space",
  apps: "Apps and what starts with Windows",
  developer: "Build folders that rebuild",
  assistant: "A second opinion, if you want one",
  history: "Undo with Restore",
};

export const ALL_PAGES = Object.keys(PAGES) as Page[];
