// A stand-in engine for a normal browser: entirely made-up Windows data for a user called
// "Alex". It keeps state (moved items disappear, restores come back, sign-in unlocks), waits
// about 600 ms per call so loading states show, and emits the same progress events as the
// real engine. URL switches for screenshots:
//   ?mock=locked   signed out, removal locked
//   ?mock=fresh    first run: onboarding, no scan yet
//   ?mock=stale    last Smart Scan was three days ago
//   ?mock=errors   some reads fail, to show the error banner
//   ?mock=fast     no artificial delays
import type * as T from "./types";

const GB = 1024 ** 3;
const MB = 1024 ** 2;
const KB = 1024;
const HOME = "C:\\Users\\Alex";
const LOCAL = HOME + "\\AppData\\Local";
const ROAMING = HOME + "\\AppData\\Roaming";
const DAY = 86400;

const params = typeof window !== "undefined" ? new URLSearchParams(window.location.search) : new URLSearchParams();
const modes = new Set((params.get("mock") ?? "").split(",").filter(Boolean));
const now = () => Math.floor(Date.now() / 1000);
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, modes.has("fast") ? Math.min(ms, 30) : ms));
const fail = (message: string) => Promise.reject(message);

// MARK: Events

const listeners = new Map<string, Set<(payload: unknown) => void>>();
export function mockListen(event: string, handler: (payload: unknown) => void): Promise<() => void> {
  if (!listeners.has(event)) listeners.set(event, new Set());
  listeners.get(event)!.add(handler);
  return Promise.resolve(() => listeners.get(event)?.delete(handler));
}
function emit(event: string, payload: unknown) {
  listeners.get(event)?.forEach((handler) => handler(payload));
}

// MARK: Candidates

type Cat = T.Candidate["category"];
let serial = 0;
function cand(p: Partial<T.Candidate> & { path: string; bytes: number; category: Cat }): T.Candidate {
  const name = p.name ?? p.path.split("\\").pop()!;
  return {
    id: p.id ?? `c${++serial}`,
    path: p.path,
    name,
    group: p.group ?? "Files",
    detail: p.detail ?? "",
    bytes: p.bytes,
    risk: p.risk ?? "safe",
    reason: p.reason ?? "",
    selected: p.selected ?? (p.risk ?? "safe") === "safe",
    blockedBy: p.blockedBy ?? null,
    ownerName: p.ownerName ?? null,
    modified: p.modified ?? now() - 3 * DAY,
    category: p.category,
  };
}

const cleanupGroups: { category: T.CleanupCategory; title: string; summary: string; items: T.Candidate[] }[] = [
  {
    category: "tempFiles", title: "Temporary files",
    summary: "Files apps make while they work and forget to clean up.",
    items: [
      cand({ id: "temp-user", name: "Your Temp folder", path: LOCAL + "\\Temp", group: "Temp", detail: "1,284 files", bytes: 2.31 * GB, category: "tempFiles",
        reason: "Windows and apps put short-lived files here. Anything older than a day is left over." }),
      cand({ id: "temp-thumbs", name: "Thumbnail cache", path: LOCAL + "\\Microsoft\\Windows\\Explorer", group: "File Explorer", detail: "thumbcache files", bytes: 318 * MB, category: "tempFiles",
        reason: "Small previews of your pictures. File Explorer makes them again when needed." }),
      cand({ id: "temp-dx", name: "DirectX shader cache", path: LOCAL + "\\D3DSCache", group: "DirectX", detail: "412 files", bytes: 486 * MB, category: "tempFiles",
        reason: "Games and apps rebuild these the next time they start." }),
      cand({ id: "temp-win", name: "Windows Temp folder", path: "C:\\Windows\\Temp", group: "Windows", detail: "Needs an administrator", bytes: 640 * MB, category: "tempFiles", risk: "restricted", selected: false,
        reason: "Belongs to Windows. Changing it needs an administrator, so MacMint only shows it." }),
    ],
  },
  {
    category: "appCaches", title: "App caches",
    summary: "Copies of web pages, pictures and updates that apps keep to load faster. They come back on their own.",
    items: [
      cand({ id: "cache-chrome", name: "Chrome cache", path: LOCAL + "\\Google\\Chrome\\User Data\\Default\\Cache", group: "Chrome", detail: "Saved web pages", bytes: 1.82 * GB, category: "appCaches",
        selected: false, blockedBy: "Chrome is open: quit it first", ownerName: "Google Chrome",
        reason: "Saved copies of websites. Chrome downloads them again when you visit." }),
      cand({ id: "cache-edge", name: "Edge cache", path: LOCAL + "\\Microsoft\\Edge\\User Data\\Default\\Cache", group: "Edge", detail: "Saved web pages", bytes: 947 * MB, category: "appCaches", ownerName: "Microsoft Edge",
        reason: "Saved copies of websites. Edge downloads them again when you visit." }),
      cand({ id: "cache-code", name: "VS Code cache", path: ROAMING + "\\Code\\CachedData", group: "VS Code", detail: "Editor cache", bytes: 612 * MB, category: "appCaches", ownerName: "Visual Studio Code",
        reason: "Speeds up starting the editor. VS Code makes it again." }),
      cand({ id: "cache-discord", name: "Discord cache", path: ROAMING + "\\discord\\Cache", group: "Discord", detail: "Images and videos from chats", bytes: 455 * MB, category: "appCaches", ownerName: "Discord",
        reason: "Pictures and videos you scrolled past. Discord loads them again when you look." }),
      cand({ id: "cache-teams", name: "Teams cache", path: LOCAL + "\\Packages\\MSTeams_8wekyb3d8bbwe\\LocalCache", group: "Teams", detail: "Chat and meeting cache", bytes: 388 * MB, category: "appCaches", ownerName: "Microsoft Teams",
        reason: "Teams keeps this to open chats faster. It builds it again." }),
      cand({ id: "cache-spotify", name: "Spotify offline data", path: LOCAL + "\\Spotify\\Data", group: "Spotify", detail: "Songs saved for offline", bytes: 1.24 * GB, category: "appCaches", risk: "review", selected: false, ownerName: "Spotify",
        reason: "May hold songs you saved for offline listening. Spotify gets them again, but only when you're online." }),
    ],
  },
  {
    category: "logsAndReports", title: "Logs and crash reports",
    summary: "Notes apps write about what happened. Useful for fixing problems, not needed day to day.",
    items: [
      cand({ id: "log-wer", name: "Windows error reports", path: "C:\\ProgramData\\Microsoft\\Windows\\WER\\ReportArchive", group: "Windows", detail: "38 reports", bytes: 214 * MB, category: "logsAndReports",
        reason: "Reports Windows already sent or no longer needs." }),
      cand({ id: "log-dumps", name: "Crash dumps", path: LOCAL + "\\CrashDumps", group: "Apps", detail: "6 files", bytes: 482 * MB, category: "logsAndReports", risk: "review", selected: false,
        reason: "Snapshots taken when an app crashed. Keep them if a support person asked for one." }),
      cand({ id: "log-steam", name: "Steam logs", path: "C:\\Program Files (x86)\\Steam\\logs", group: "Steam", detail: "Old log files", bytes: 96 * MB, category: "logsAndReports", ownerName: "Steam",
        reason: "Steam writes new logs every time it runs." }),
    ],
  },
  {
    category: "developerCaches", title: "Developer caches",
    summary: "Packages your build tools downloaded. They download again when a project needs them.",
    items: [
      cand({ id: "dev-npm", name: "npm cache", path: LOCAL + "\\npm-cache", group: "npm", detail: "Downloaded packages", bytes: 2.64 * GB, category: "developerCaches",
        reason: "npm keeps a copy of every package it downloaded. It fetches them again when needed." }),
      cand({ id: "dev-pip", name: "pip cache", path: LOCAL + "\\pip\\cache", group: "pip", detail: "Downloaded packages", bytes: 384 * MB, category: "developerCaches",
        reason: "Python packages pip downloaded. pip fetches them again when needed." }),
      cand({ id: "dev-nuget", name: "NuGet packages", path: HOME + "\\.nuget\\packages", group: "NuGet", detail: "Package folder", bytes: 1.12 * GB, category: "developerCaches", risk: "review", selected: false,
        reason: "Some projects need these to build when you're offline." }),
    ],
  },
  {
    category: "installers", title: "Installers",
    summary: "Setup files you already ran. The apps are installed, so these copies aren't needed.",
    items: [
      cand({ id: "inst-code", name: "VSCodeUserSetup-x64-1.95.3.exe", path: HOME + "\\Downloads\\VSCodeUserSetup-x64-1.95.3.exe", group: "Downloads", detail: "Visual Studio Code is installed", bytes: 98 * MB, category: "installers", risk: "review", selected: false,
        reason: "The file that installed Visual Studio Code. You can download it again any time." }),
      cand({ id: "inst-discord", name: "DiscordSetup.exe", path: HOME + "\\Downloads\\DiscordSetup.exe", group: "Downloads", detail: "Discord is installed", bytes: 112 * MB, category: "installers", risk: "review", selected: false,
        reason: "The file that installed Discord." }),
      cand({ id: "inst-steam", name: "SteamSetup.exe", path: HOME + "\\Downloads\\SteamSetup.exe", group: "Downloads", detail: "Steam is installed", bytes: 2.3 * MB, category: "installers", risk: "review", selected: false,
        reason: "The file that installed Steam." }),
    ],
  },
];

function devItem(p: Partial<T.DeveloperItem> & { id: string; project: string; name: string; bytes: number; tool: string; kind: T.DeveloperItem["kind"]; lastDays: number }): T.DeveloperItem {
  const project = HOME + "\\Projects\\" + p.project;
  const base = cand({ id: p.id, path: project + "\\" + p.name, name: p.name, bytes: p.bytes, category: "developer", group: p.tool, risk: p.risk ?? "safe",
    detail: p.kind === "installedDependencies" ? "Installed dependencies" : "Build output",
    selected: (p.risk ?? "safe") === "safe" && p.lastDays > 30, reason: p.reason ?? "", modified: now() - p.lastDays * DAY });
  return { ...base, project, projectName: p.project, tool: p.tool, kind: p.kind, lastActivity: now() - p.lastDays * DAY };
}

const developerItems: T.DeveloperItem[] = [
  devItem({ id: "dev-shop-nm", project: "web-shop", name: "node_modules", bytes: 812 * MB, tool: "npm", kind: "installedDependencies", lastDays: 2,
    reason: "Installed packages. Run npm install to get them back." }),
  devItem({ id: "dev-shop-next", project: "web-shop", name: ".next", bytes: 296 * MB, tool: "Next.js", kind: "generatedOutput", lastDays: 2,
    reason: "Build output. npm run build makes it again." }),
  devItem({ id: "dev-rust-target", project: "tiny-rust", name: "target", bytes: 3.41 * GB, tool: "Cargo", kind: "generatedOutput", lastDays: 47,
    reason: "Build output. cargo build makes it again. The first build after can take a few minutes." }),
  devItem({ id: "dev-blog-nm", project: "old-blog", name: "node_modules", bytes: 534 * MB, tool: "npm", kind: "installedDependencies", lastDays: 210,
    reason: "Installed packages. Run npm install to get them back." }),
  devItem({ id: "dev-blog-dist", project: "old-blog", name: "dist", bytes: 41 * MB, tool: "Vite", kind: "generatedOutput", lastDays: 210,
    reason: "Build output. npm run build makes it again." }),
  devItem({ id: "dev-api-venv", project: "api-tools", name: ".venv", bytes: 690 * MB, tool: "Python", kind: "installedDependencies", lastDays: 12,
    reason: "A Python environment. pip install -r requirements.txt makes it again." }),
  devItem({ id: "dev-unity-lib", project: "unity-sandbox", name: "Library", bytes: 4.8 * GB, tool: "Unity", kind: "generatedOutput", lastDays: 95, risk: "review",
    reason: "Unity's import cache. Unity rebuilds it when you open the project, which is slow the first time." }),
];

const developerCaches: T.Candidate[] = [
  cand({ id: "devc-cargo", name: "Cargo registry", path: HOME + "\\.cargo\\registry", group: "Cargo", detail: "Downloaded crates", bytes: 1.26 * GB, category: "developer",
    reason: "Crates Cargo downloaded. It fetches them again when a project needs them." }),
  cand({ id: "devc-gradle", name: "Gradle caches", path: HOME + "\\.gradle\\caches", group: "Gradle", detail: "Downloaded libraries", bytes: 2.1 * GB, category: "developer",
    reason: "Libraries Gradle downloaded. It fetches them again on the next build." }),
  cand({ id: "devc-yarn", name: "Yarn cache", path: LOCAL + "\\Yarn\\Cache", group: "Yarn", detail: "Downloaded packages", bytes: 760 * MB, category: "developer",
    reason: "Packages Yarn downloaded. It fetches them again when needed." }),
];

const largeFiles: T.Candidate[] = [
  cand({ id: "lf-vm", name: "Win11Dev.vdi", path: HOME + "\\VirtualBox VMs\\Win11Dev\\Win11Dev.vdi", group: "VirtualBox", detail: "Virtual machine disk", bytes: 21.4 * GB, category: "largeFile", risk: "review", selected: false, modified: now() - 140 * DAY,
    reason: "A whole virtual computer. Keep it if you still use this virtual machine." }),
  cand({ id: "lf-ubuntu", name: "ubuntu-24.04.1-desktop-amd64.iso", path: HOME + "\\Downloads\\ubuntu-24.04.1-desktop-amd64.iso", group: "Downloads", detail: "Disc image", bytes: 5.86 * GB, category: "largeFile", risk: "review", selected: false, modified: now() - 120 * DAY,
    reason: "A disc image you downloaded. You can download it again." }),
  cand({ id: "lf-trip", name: "Family trip 2023.mp4", path: HOME + "\\Videos\\Family trip 2023.mp4", group: "Videos", detail: "Video", bytes: 4.12 * GB, category: "largeFile", risk: "review", selected: false, modified: now() - 400 * DAY,
    reason: "A personal video. Only you know if it's backed up somewhere else." }),
  cand({ id: "lf-backup", name: "photos-backup-2022.zip", path: HOME + "\\Documents\\photos-backup-2022.zip", group: "Documents", detail: "Compressed folder", bytes: 3.4 * GB, category: "largeFile", risk: "review", selected: false, modified: now() - 700 * DAY,
    reason: "A backup. Check it's stored somewhere else before it goes." }),
  cand({ id: "lf-obs", name: "2024-08-14 19-02-11.mkv", path: HOME + "\\Videos\\Captures\\2024-08-14 19-02-11.mkv", group: "Videos", detail: "Screen recording", bytes: 2.85 * GB, category: "largeFile", risk: "review", selected: false, modified: now() - 90 * DAY,
    reason: "A screen recording from OBS Studio." }),
  cand({ id: "lf-mods", name: "game-mods.7z", path: HOME + "\\Downloads\\game-mods.7z", group: "Downloads", detail: "Compressed folder", bytes: 1.6 * GB, category: "largeFile", risk: "review", selected: false, modified: now() - 60 * DAY,
    reason: "A download you may have already unpacked." }),
  cand({ id: "lf-sql", name: "SQLServer2022-x64-ENU.iso", path: HOME + "\\Downloads\\SQLServer2022-x64-ENU.iso", group: "Downloads", detail: "Disc image", bytes: 1.1 * GB, category: "largeFile", risk: "review", selected: false, modified: now() - 230 * DAY,
    reason: "An installer disc image. You can download it again." }),
  cand({ id: "lf-lecture", name: "lecture-recording.mp4", path: HOME + "\\Desktop\\lecture-recording.mp4", group: "Desktop", detail: "Video", bytes: 860 * MB, category: "largeFile", risk: "review", selected: false, modified: now() - 33 * DAY,
    reason: "A video on your desktop." }),
  cand({ id: "lf-psd", name: "poster-final-v3.psd", path: HOME + "\\Documents\\Design\\poster-final-v3.psd", group: "Documents", detail: "Photoshop file", bytes: 412 * MB, category: "largeFile", risk: "review", selected: false, modified: now() - 75 * DAY,
    reason: "A design file. Keep it if you might edit it again." }),
  cand({ id: "lf-dataset", name: "dataset-sample.csv", path: HOME + "\\Projects\\api-tools\\data\\dataset-sample.csv", group: "Projects", detail: "Spreadsheet data", bytes: 312 * MB, category: "largeFile", risk: "review", selected: false, modified: now() - 18 * DAY,
    reason: "Data in a project folder." }),
  cand({ id: "lf-music", name: "Live set 2021.wav", path: HOME + "\\Music\\Live set 2021.wav", group: "Music", detail: "Audio", bytes: 180 * MB, category: "largeFile", risk: "review", selected: false, modified: now() - 900 * DAY,
    reason: "An audio recording." }),
];

const oldDownloads: T.Candidate[] = [
  cand({ id: "od-nvidia", name: "546.33-desktop-win10-win11-64bit.exe", path: HOME + "\\Downloads\\546.33-desktop-win10-win11-64bit.exe", group: "Downloads", detail: "Downloaded 11 months ago · not opened since", bytes: 640 * MB, category: "download", risk: "review", selected: false, modified: now() - 330 * DAY,
    reason: "An old graphics driver installer. Newer drivers replace it." }),
  cand({ id: "od-rec", name: "Screen Recording 2024-03-02.mp4", path: HOME + "\\Downloads\\Screen Recording 2024-03-02.mp4", group: "Downloads", detail: "Downloaded 8 months ago · never opened", bytes: 612 * MB, category: "download", risk: "review", selected: false, modified: now() - 250 * DAY,
    reason: "A video in Downloads that hasn't been opened." }),
  cand({ id: "od-zoom", name: "ZoomInstallerFull.msi", path: HOME + "\\Downloads\\ZoomInstallerFull.msi", group: "Downloads", detail: "Downloaded 6 months ago · Zoom is installed", bytes: 85 * MB, category: "download", risk: "review", selected: false, modified: now() - 190 * DAY,
    reason: "Zoom is already installed, so this setup file isn't needed." }),
  cand({ id: "od-fonts", name: "fonts-pack.zip", path: HOME + "\\Downloads\\fonts-pack.zip", group: "Downloads", detail: "Downloaded 5 months ago", bytes: 148 * MB, category: "download", risk: "review", selected: false, modified: now() - 160 * DAY,
    reason: "A compressed folder you may have already unpacked." }),
  cand({ id: "od-resume", name: "old-resume.docx", path: HOME + "\\Downloads\\old-resume.docx", group: "Downloads", detail: "Downloaded a year ago", bytes: 48 * KB, category: "download", risk: "review", selected: false, modified: now() - 380 * DAY,
    reason: "A document. Check you have a newer copy." }),
];

function dupFile(id: string, path: string, bytes: number, days: number): T.Candidate {
  return cand({ id, path, bytes, category: "duplicate", risk: "review", selected: false, group: "Duplicates", detail: "Exact copy", modified: now() - days * DAY,
    reason: "Byte-for-byte the same as the other files in this group." });
}
const duplicateGroups: T.DuplicateGroup[] = [
  { id: "dg-video", bytes: 380 * MB, files: [
    dupFile("dv-1", HOME + "\\Videos\\project-demo.mp4", 380 * MB, 40),
    dupFile("dv-2", HOME + "\\Downloads\\project-demo.mp4", 380 * MB, 41) ] },
  { id: "dg-setup", bytes: 96 * MB, files: [
    dupFile("ds-1", HOME + "\\Projects\\web-shop\\assets\\setup-assets.zip", 96 * MB, 20),
    dupFile("ds-2", HOME + "\\Downloads\\setup-assets.zip", 96 * MB, 22),
    dupFile("ds-3", HOME + "\\Desktop\\setup-assets (1).zip", 96 * MB, 22) ] },
  { id: "dg-wedding", bytes: 12.4 * MB, files: [
    dupFile("dw-1", HOME + "\\Pictures\\Wedding\\DSC_0412.NEF", 12.4 * MB, 500),
    dupFile("dw-2", HOME + "\\Pictures\\Imports\\DSC_0412.NEF", 12.4 * MB, 480),
    dupFile("dw-3", HOME + "\\OneDrive\\Pictures\\DSC_0412.NEF", 12.4 * MB, 480),
    dupFile("dw-4", HOME + "\\Desktop\\to sort\\DSC_0412.NEF", 12.4 * MB, 300) ] },
  { id: "dg-photo", bytes: 4.2 * MB, files: [
    dupFile("dp-1", HOME + "\\Pictures\\Phone\\IMG_2041.jpg", 4.2 * MB, 200),
    dupFile("dp-2", HOME + "\\Pictures\\Imports\\IMG_2041.jpg", 4.2 * MB, 190),
    dupFile("dp-3", HOME + "\\Desktop\\IMG_2041 (1).jpg", 4.2 * MB, 100) ] },
  { id: "dg-tax", bytes: 2.1 * MB, files: [
    dupFile("dt-1", HOME + "\\Documents\\Taxes\\Tax return 2023.pdf", 2.1 * MB, 230),
    dupFile("dt-2", HOME + "\\Downloads\\Tax return 2023.pdf", 2.1 * MB, 231) ] },
];

// Every candidate the UI can send back, by id.
const registry = new Map<string, T.Candidate>();
function register(list: T.Candidate[]) { for (const c of list) registry.set(c.id, c); }
cleanupGroups.forEach((g) => register(g.items));
register(developerItems); register(developerCaches); register(largeFiles); register(oldDownloads);
duplicateGroups.forEach((g) => register(g.files));

const moved = new Set<string>();
const present = <C extends T.Candidate>(list: C[]) => list.filter((c) => !moved.has(c.id));

// MARK: Apps, startup, processes

function app(p: Partial<T.InstalledApp> & { id: string; name: string }): T.InstalledApp {
  return { publisher: null, version: null, bytes: null, installDate: null, location: null, icon: null, canUninstall: true, running: false, scope: "currentUser", ...p };
}
let apps: T.InstalledApp[] = [
  app({ id: "chrome", name: "Google Chrome", publisher: "Google LLC", version: "131.0.6778.86", bytes: 612 * MB, installDate: "2023-02-11", location: "C:\\Program Files\\Google\\Chrome\\Application", running: true, scope: "allUsers" }),
  app({ id: "edge", name: "Microsoft Edge", publisher: "Microsoft Corporation", version: "131.0.2903.70", bytes: 588 * MB, installDate: "2024-10-30", location: "C:\\Program Files (x86)\\Microsoft\\Edge\\Application", canUninstall: false, scope: "allUsers" }),
  app({ id: "code", name: "Microsoft Visual Studio Code (User)", publisher: "Microsoft Corporation", version: "1.95.3", bytes: 412 * MB, installDate: "2024-11-14", location: LOCAL + "\\Programs\\Microsoft VS Code", running: true }),
  app({ id: "discord", name: "Discord", publisher: "Discord Inc.", version: "1.0.9171", bytes: 389 * MB, installDate: "2023-06-02", location: LOCAL + "\\Discord", running: true }),
  app({ id: "spotify", name: "Spotify", publisher: "Spotify AB", version: "1.2.50.335", bytes: 302 * MB, installDate: "2023-01-19", location: ROAMING + "\\Spotify" }),
  app({ id: "steam", name: "Steam", publisher: "Valve Corporation", version: "2.10.91.91", bytes: 1.24 * GB, installDate: "2022-12-24", location: "C:\\Program Files (x86)\\Steam", scope: "allUsers" }),
  app({ id: "zoom", name: "Zoom Workplace", publisher: "Zoom Video Communications, Inc.", version: "6.2.11", bytes: 268 * MB, installDate: "2024-05-08", location: ROAMING + "\\Zoom" }),
  app({ id: "notion", name: "Notion", publisher: "Notion Labs, Inc.", version: "4.2.0", bytes: 352 * MB, installDate: "2024-02-17", location: LOCAL + "\\Programs\\Notion" }),
  app({ id: "obs", name: "OBS Studio", publisher: "OBS Project", version: "30.2.3", bytes: 340 * MB, installDate: "2024-08-01", location: "C:\\Program Files\\obs-studio", scope: "allUsers" }),
  app({ id: "gimp", name: "GIMP 2.10.38", publisher: "The GIMP Team", version: "2.10.38", bytes: 410 * MB, installDate: "2022-04-03", location: "C:\\Program Files\\GIMP 2", scope: "allUsers" }),
  app({ id: "python", name: "Python 3.12.7 (64-bit)", publisher: "Python Software Foundation", version: "3.12.7", bytes: 102 * MB, installDate: "2024-10-02", location: LOCAL + "\\Programs\\Python\\Python312" }),
  app({ id: "node", name: "Node.js", publisher: "Node.js Foundation", version: "22.11.0", bytes: 98 * MB, installDate: "2024-11-01", location: "C:\\Program Files\\nodejs", scope: "allUsers" }),
  app({ id: "rustup", name: "Rustup: the Rust toolchain installer", publisher: null, version: "1.27.1", bytes: null, installDate: "2024-03-12", location: HOME + "\\.cargo" }),
  app({ id: "7zip", name: "7-Zip 24.08 (x64)", publisher: "Igor Pavlov", version: "24.08", bytes: 5.6 * MB, installDate: "2024-08-20", location: "C:\\Program Files\\7-Zip", scope: "allUsers" }),
];

let startup: T.StartupItem[] = [
  { id: "su-discord", name: "Discord", command: LOCAL + "\\Discord\\Update.exe --processStart Discord.exe", location: "currentUserRun", enabled: true, canToggle: true, publisher: "Discord Inc." },
  { id: "su-spotify", name: "Spotify", command: ROAMING + "\\Spotify\\Spotify.exe /minimized /uri=spotify:autostart", location: "currentUserRun", enabled: true, canToggle: true, publisher: "Spotify AB" },
  { id: "su-steam", name: "Steam", command: "\"C:\\Program Files (x86)\\Steam\\steam.exe\" -silent", location: "currentUserRun", enabled: true, canToggle: true, publisher: "Valve Corporation" },
  { id: "su-onedrive", name: "Microsoft OneDrive", command: LOCAL + "\\Microsoft\\OneDrive\\OneDrive.exe /background", location: "currentUserRun", enabled: true, canToggle: true, publisher: "Microsoft Corporation" },
  { id: "su-teams", name: "Microsoft Teams", command: LOCAL + "\\Microsoft\\WindowsApps\\ms-teams.exe msteams:system-initiated", location: "currentUserRun", enabled: false, canToggle: true, publisher: "Microsoft Corporation" },
  { id: "su-zoom", name: "Zoom", command: HOME + "\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\Zoom.lnk", location: "startupFolder", enabled: true, canToggle: true, publisher: "Zoom Video Communications, Inc." },
  { id: "su-notion", name: "Notion", command: HOME + "\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\Notion.lnk", location: "startupFolder", enabled: false, canToggle: true, publisher: "Notion Labs, Inc." },
  { id: "su-security", name: "Windows Security notification icon", command: "%windir%\\system32\\SecurityHealthSystray.exe", location: "allUsersRun", enabled: true, canToggle: false, publisher: "Microsoft Corporation" },
  { id: "su-realtek", name: "Realtek Audio Universal Service", command: "\"C:\\Windows\\System32\\RtkAudUService64.exe\" -background", location: "allUsersRun", enabled: true, canToggle: false, publisher: "Realtek Semiconductor" },
  { id: "su-logi", name: "Logi Options+", command: "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp\\Logi Options+.lnk", location: "allUsersStartupFolder", enabled: true, canToggle: false, publisher: "Logitech" },
];

const processes: T.ProcessInfo[] = [
  { pid: 11240, name: "Google Chrome", cpuPercent: 18.4, memory: 2.1 * GB, lowered: false, canLower: true },
  { pid: 20412, name: "Node.js", cpuPercent: 12.3, memory: 920 * MB, lowered: false, canLower: true },
  { pid: 8812, name: "Visual Studio Code", cpuPercent: 6.2, memory: 1.3 * GB, lowered: false, canLower: true },
  { pid: 4120, name: "Antimalware Service Executable", cpuPercent: 4.7, memory: 280 * MB, lowered: false, canLower: false },
  { pid: 15004, name: "Discord", cpuPercent: 2.1, memory: 640 * MB, lowered: false, canLower: true },
  { pid: 17320, name: "Microsoft Teams", cpuPercent: 1.4, memory: 820 * MB, lowered: false, canLower: true },
  { pid: 9016, name: "Spotify", cpuPercent: 0.8, memory: 410 * MB, lowered: false, canLower: true },
  { pid: 6644, name: "Windows Explorer", cpuPercent: 0.6, memory: 190 * MB, lowered: false, canLower: false },
  { pid: 12880, name: "Steam", cpuPercent: 0.3, memory: 260 * MB, lowered: false, canLower: true },
  { pid: 7712, name: "Microsoft OneDrive", cpuPercent: 0.2, memory: 120 * MB, lowered: false, canLower: true },
];

// MARK: Disks and storage map

const C_TOTAL = 476 * GB;
let cFree = 61.3 * GB;
let recycleBin: T.RecycleBinInfo = { bytes: 3.2 * GB, items: 214 };

const known: Record<string, [string, number, boolean, number?][]> = {
  "C:\\": [["Users", 268 * GB, true], ["Program Files (x86)", 58.2 * GB, true], ["Windows", 31.2 * GB, true], ["Program Files", 24.6 * GB, true],
    ["pagefile.sys", 9.5 * GB, false], ["ProgramData", 7.4 * GB, true], ["hiberfil.sys", 6.3 * GB, false], ["$Recycle.Bin", 3.2 * GB, true],
    ["Recovery", 1.0 * GB, true, 1], ["swapfile.sys", 256 * MB, false], ["System Volume Information", 0, true, 1]],
  "C:\\Users": [["Alex", 262 * GB, true], ["Public", 1.2 * GB, true], ["Default", 412 * MB, true, 3]],
  [HOME]: [["AppData", 64.2 * GB, true], ["Videos", 41.3 * GB, true], ["VirtualBox VMs", 38.1 * GB, true], ["Pictures", 29.4 * GB, true],
    ["Downloads", 22.4 * GB, true], ["OneDrive", 21.0 * GB, true], ["Projects", 18.6 * GB, true], ["Documents", 14.1 * GB, true],
    ["Music", 6.0 * GB, true], [".cargo", 3.4 * GB, true], [".gradle", 2.1 * GB, true], ["Desktop", 2.1 * GB, true], [".nuget", 1.1 * GB, true]],
  [HOME + "\\AppData"]: [["Local", 51.8 * GB, true, 4], ["Roaming", 11.9 * GB, true], ["LocalLow", 520 * MB, true]],
  [LOCAL]: [["Packages", 12.4 * GB, true, 2], ["Google", 6.1 * GB, true], ["Microsoft", 5.8 * GB, true, 1], ["npm-cache", 2.64 * GB, true], ["Temp", 2.31 * GB, true, 2],
    ["Programs", 2.2 * GB, true], ["Spotify", 1.6 * GB, true], ["Discord", 980 * MB, true], ["CrashDumps", 482 * MB, true], ["D3DSCache", 486 * MB, true], ["pip", 384 * MB, true]],
  [HOME + "\\Projects"]: [["unity-sandbox", 7.9 * GB, true], ["tiny-rust", 3.6 * GB, true], ["web-shop", 1.4 * GB, true], ["api-tools", 1.2 * GB, true], ["old-blog", 610 * MB, true], ["keep-me", 120 * MB, true]],
  "C:\\Program Files (x86)": [["Steam", 52.8 * GB, true], ["Microsoft", 2.9 * GB, true], ["Common Files", 1.1 * GB, true]],
  "D:\\": [["Games", 220 * GB, true], ["Backups", 140 * GB, true], ["Media", 59 * GB, true]],
};
const sizes = new Map<string, number>([["C:\\", C_TOTAL - 61.3 * GB], ["D:\\", 419 * GB]]);
const join = (parent: string, name: string) => (parent.endsWith("\\") ? parent + name : parent + "\\" + name);

function hash(text: string): number {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return h >>> 0;
}

function breakdown(path: string): T.StorageBreakdown {
  const list = known[path];
  let children: T.FolderUsage[];
  if (list) {
    children = list.map(([name, b, isDir, unreadable]) => ({ path: join(path, name), name, bytes: Math.round(b), isDir, files: isDir ? Math.round(b / (2.3 * MB)) + 3 : 1, unreadable: unreadable ?? 0 }));
  } else {
    // A made-up but stable split of a folder we have no hand-written data for.
    const total = sizes.get(path) ?? 1 * GB;
    const folders = ["Cache", "Data", "Media", "Assets", "Logs", "Backups", "Archive", "Settings"];
    const files = ["index.db", "content.pak", "app.log", "bundle.bin"];
    let seed = hash(path);
    const rnd = () => { seed = Math.imul(seed ^ (seed >>> 15), 2246822507) >>> 0; return (seed % 1000) / 1000; };
    const count = 5 + Math.floor(rnd() * 4);
    const weights = Array.from({ length: count }, (_, i) => Math.pow(0.55, i) * (0.6 + rnd()));
    const wsum = weights.reduce((a, b) => a + b, 0);
    children = weights.map((w, i) => {
      const isDir = i < count - 2;
      const name = isDir ? folders[(i + (seed % 3)) % folders.length] : files[i % files.length];
      const b = Math.round((total * w) / wsum);
      return { path: join(path, name), name, bytes: b, isDir, files: isDir ? Math.max(1, Math.round(b / (1.7 * MB))) : 1, unreadable: 0 };
    });
  }
  children.sort((a, b) => b.bytes - a.bytes);
  for (const c of children) sizes.set(c.path, c.bytes);
  const total = sizes.get(path) ?? children.reduce((a, c) => a + c.bytes, 0);
  return { path, bytes: total, children };
}

// MARK: Account, settings, history

const signedIn: T.AccountStatus = {
  signedIn: true, email: "alex@example.com", name: "Alex Rivera", plan: "Pro", unlocked: true, offline: false,
  deviceName: "ALEX-LAPTOP", message: null, aiAvailable: true,
};
const signedOut: T.AccountStatus = {
  signedIn: false, email: null, name: null, plan: null, unlocked: false, offline: false, deviceName: "ALEX-LAPTOP", message: null, aiAvailable: false,
};
let account: T.AccountStatus = modes.has("locked") || modes.has("fresh") ? { ...signedOut } : { ...signedIn };

let settings: T.Settings = {
  theme: "system",
  exclusions: [HOME + "\\Projects\\keep-me"],
  hasOnboarded: !modes.has("fresh"),
  hasTakenTour: !modes.has("fresh"),
  aiEnabled: false,
  checkUpdatesAutomatically: true,
};

let history: T.HistoryEntry[] = [
  { id: "h1", title: "Cleanup", date: now() - 2 * DAY - 3600 * 5, bytes: 3.1 * GB, notes: "Moved 5 items to the Recycle Bin. 1 item was skipped because Chrome was open.",
    receipts: [
      { originalPath: LOCAL + "\\Temp\\vscode-updater", bytes: 1.4 * GB, trashedAt: now() - 2 * DAY - 3600 * 5, restored: false },
      { originalPath: LOCAL + "\\Microsoft\\Edge\\User Data\\Default\\Code Cache", bytes: 820 * MB, trashedAt: now() - 2 * DAY - 3600 * 5, restored: false },
      { originalPath: ROAMING + "\\Slack\\Cache", bytes: 610 * MB, trashedAt: now() - 2 * DAY - 3600 * 5, restored: true },
      { originalPath: LOCAL + "\\CrashDumps\\explorer.exe.10440.dmp", bytes: 196 * MB, trashedAt: now() - 2 * DAY - 3600 * 5, restored: false },
      { originalPath: "C:\\ProgramData\\Microsoft\\Windows\\WER\\ReportQueue", bytes: 148 * MB, trashedAt: now() - 2 * DAY - 3600 * 5, restored: false },
    ], uncertain: [] },
  { id: "h2", title: "Developer", date: now() - 9 * DAY, bytes: 2.2 * GB, notes: "Removed build output from 2 projects. Run the build again to get it back.",
    receipts: [
      { originalPath: HOME + "\\Projects\\game-jam\\target", bytes: 1.7 * GB, trashedAt: now() - 9 * DAY, restored: false },
      { originalPath: HOME + "\\Projects\\portfolio\\node_modules", bytes: 512 * MB, trashedAt: now() - 9 * DAY, restored: false },
    ], uncertain: [] },
  { id: "h3", title: "Large Files", date: now() - 24 * DAY, bytes: 6.3 * GB, notes: "Moved 2 large files to the Recycle Bin.",
    receipts: [
      { originalPath: HOME + "\\Downloads\\Win11_23H2_English_x64.iso", bytes: 6.2 * GB, trashedAt: now() - 24 * DAY, restored: false },
      { originalPath: HOME + "\\Downloads\\old-drivers.zip", bytes: 104 * MB, trashedAt: now() - 24 * DAY, restored: false },
    ], uncertain: [HOME + "\\Downloads\\old-drivers.zip: Windows didn't confirm where it went. Look for it in the Recycle Bin."] },
];

// MARK: Smart Scan

const AREAS = [
  { id: "temp", title: "Temporary files" },
  { id: "caches", title: "App caches" },
  { id: "logs", title: "Logs and crash reports" },
  { id: "devcaches", title: "Developer caches" },
  { id: "installers", title: "Installers and old downloads" },
  { id: "projects", title: "Project build folders" },
  { id: "recycle", title: "Recycle Bin" },
];

function buildSmartScan(checkedAt: number): T.SmartScan {
  const groupBytes = (cat: T.CleanupCategory) => present(cleanupGroups.find((g) => g.category === cat)!.items).reduce((a, c) => a + c.bytes, 0);
  const devBytes = present(developerItems).reduce((a, c) => a + c.bytes, 0);
  const dlBytes = present(oldDownloads).reduce((a, c) => a + c.bytes, 0) + groupBytes("installers");
  const areas: T.ScanArea[] = [
    { id: "temp", title: "Temporary files", status: "partial", bytesFound: groupBytes("tempFiles"), note: "The Windows Temp folder needs an administrator, so it was only measured." },
    { id: "caches", title: "App caches", status: "checked", bytesFound: groupBytes("appCaches"), note: null },
    { id: "logs", title: "Logs and crash reports", status: "checked", bytesFound: groupBytes("logsAndReports"), note: null },
    { id: "devcaches", title: "Developer caches", status: "checked", bytesFound: groupBytes("developerCaches"), note: null },
    { id: "installers", title: "Installers and old downloads", status: "checked", bytesFound: dlBytes, note: null },
    { id: "projects", title: "Project build folders", status: "checked", bytesFound: devBytes, note: "Looked in C:\\Users\\Alex\\Projects." },
    { id: "recycle", title: "Recycle Bin", status: "checked", bytesFound: recycleBin.bytes, note: null },
  ];
  const safeIds = (list: T.Candidate[]) => present(list).filter((c) => c.risk === "safe" && !c.blockedBy).map((c) => c.id);
  const safeCleanup = cleanupGroups.filter((g) => g.category !== "installers").flatMap((g) => g.items);
  const safeCleanupBytes = present(safeCleanup).filter((c) => c.risk === "safe" && !c.blockedBy).reduce((a, c) => a + c.bytes, 0);
  const oldDev = present(developerItems).filter((d) => d.selected);
  const recs: T.Recommendation[] = [];
  if (safeCleanupBytes > 0) recs.push({ id: "r-caches", title: "Clear caches and temporary files", detail: "They rebuild on their own. Chrome is open, so its cache is left for later.",
    bytes: safeCleanupBytes, candidateIds: safeIds(safeCleanup), kind: "clean", page: "cleanup", tone: "sky" });
  if (oldDev.length) recs.push({ id: "r-dev", title: `Build folders in ${new Set(oldDev.map((d) => d.projectName)).size} quiet projects`, detail: "Projects you haven't touched in a month. Your build tools make these again.",
    bytes: oldDev.reduce((a, c) => a + c.bytes, 0), candidateIds: oldDev.map((d) => d.id), kind: "clean", page: "developer", tone: "amber" });
  const reviewCache = present(safeCleanup).filter((c) => c.risk === "review");
  if (reviewCache.length) recs.push({ id: "r-review", title: "Offline music, crash dumps and packages", detail: "These may matter to you. Look before they go.",
    bytes: reviewCache.reduce((a, c) => a + c.bytes, 0), candidateIds: reviewCache.map((c) => c.id), kind: "review", page: "cleanup", tone: "violet" });
  const dls = [...present(oldDownloads), ...present(cleanupGroups.find((g) => g.category === "installers")!.items)];
  if (dls.length) recs.push({ id: "r-downloads", title: "Old downloads and installers", detail: `${dls.length} files in Downloads you haven't opened in months.`,
    bytes: dls.reduce((a, c) => a + c.bytes, 0), candidateIds: dls.map((c) => c.id), kind: "review", page: "cleanup", tone: "mint" });
  if (recycleBin.bytes > 0) recs.push({ id: "r-bin", title: "Empty the Recycle Bin", detail: `${recycleBin.items} items are waiting there. Space comes back only after it's emptied.`,
    bytes: recycleBin.bytes, candidateIds: [], kind: "advice", page: "cleanup", tone: "slate" });
  const enabled = startup.filter((s) => s.enabled).length;
  recs.push({ id: "r-startup", title: `${enabled} apps start when you sign in`, detail: "Turning a few off can make startup faster. It doesn't remove them.",
    bytes: 0, candidateIds: [], kind: "advice", page: "startup", tone: "violet" });
  return { checkedAt, areas, recommendations: recs,
    reclaimableBytes: recs.filter((r) => r.kind === "clean").reduce((a, r) => a + r.bytes, 0) };
}

let lastScan: T.SmartScan | null = modes.has("fresh") ? null : buildSmartScan(now() - (modes.has("stale") ? 3 * DAY : 3 * 3600));
let scanCancelled = false;
let opCancelled = false;

// MARK: Plans and operations

const plans = new Map<string, T.OperationPlan>();
function sourceFor(c: T.Candidate): string {
  switch (c.category) {
    case "developer": return "Developer";
    case "largeFile": return "Large Files";
    case "duplicate": return "Duplicates";
    case "download": return "Old downloads";
    case "leftover": return "App leftovers";
    default: return "Cleanup";
  }
}

function preparePlan(title: string, ids: string[]): T.OperationPlan {
  const items: T.PlanItem[] = [];
  const rejected: { path: string; message: string }[] = [];
  const chosen = ids.map((id) => registry.get(id)).filter((c): c is T.Candidate => !!c);
  for (const id of ids) if (!registry.has(id) || moved.has(id)) rejected.push({ path: id, message: "This item is gone now. Scan again to refresh the list." });
  for (const c of chosen) {
    if (moved.has(c.id)) continue;
    if (c.risk === "restricted") { rejected.push({ path: c.path, message: "It belongs to Windows. MacMint won't move it." }); continue; }
    if (c.blockedBy) { rejected.push({ path: c.path, message: c.blockedBy + "." }); continue; }
    if (settings.exclusions.some((e) => c.path.toLowerCase().startsWith(e.toLowerCase()))) { rejected.push({ path: c.path, message: "It's on your exclusions list." }); continue; }
    if (chosen.some((o) => o !== c && c.path.toLowerCase().startsWith(o.path.toLowerCase() + "\\"))) continue; // inside another picked folder
    items.push({ id: c.id, path: c.path, name: c.name, expectedBytes: c.bytes, reason: c.reason, source: sourceFor(c), needsAttention: c.risk === "review" });
  }
  const plan: T.OperationPlan = { planId: "plan-" + Math.random().toString(36).slice(2, 10), title, items, rejected, totalBytes: items.reduce((a, i) => a + i.expectedBytes, 0) };
  plans.set(plan.planId, plan);
  return plan;
}

async function runPlan(planId: string): Promise<T.OperationReport> {
  const plan = plans.get(planId);
  if (!plan) return fail("That review expired. Please review the items again.");
  opCancelled = false;
  const startedAt = now();
  const outcomes: T.ItemOutcome[] = [];
  let bytesMoved = 0;
  emit("operation-progress", { completed: 0, total: plan.items.length, bytesMoved: 0 } satisfies T.OperationProgress);
  for (const item of plan.items) {
    if (opCancelled) { outcomes.push({ item, status: "notAttempted", message: "Stopped before this item." }); continue; }
    await sleep(Math.max(180, 1400 / Math.max(1, plan.items.length)));
    if (item.id === "cache-discord") {
      outcomes.push({ item, status: "skipped", message: "Discord started using this folder again, so it was left in place. Quit Discord and try again." });
    } else {
      moved.add(item.id);
      bytesMoved += item.expectedBytes;
      outcomes.push({ item, status: "moved", message: null });
    }
    emit("operation-progress", { completed: outcomes.length, total: plan.items.length, bytesMoved } satisfies T.OperationProgress);
  }
  const movedItems = outcomes.filter((o) => o.status === "moved");
  const skipped = outcomes.filter((o) => o.status !== "moved" && o.status !== "notAttempted").length;
  const notAttempted = outcomes.filter((o) => o.status === "notAttempted").length;
  recycleBin = { bytes: recycleBin.bytes + bytesMoved, items: recycleBin.items + movedItems.length };
  if (movedItems.length) {
    history = [{ id: "h" + Date.now(), title: plan.title, date: now(), bytes: bytesMoved,
      notes: `Moved ${movedItems.length} item${movedItems.length === 1 ? "" : "s"} to the Recycle Bin.` + (skipped ? ` ${skipped} skipped.` : ""),
      receipts: movedItems.map((o) => ({ originalPath: o.item.path, bytes: o.item.expectedBytes, trashedAt: now(), restored: false })), uncertain: [] }, ...history];
  }
  if (lastScan) lastScan = buildSmartScan(lastScan.checkedAt);
  plans.delete(planId);
  const parts = [`Moved ${movedItems.length} item${movedItems.length === 1 ? "" : "s"} to the Recycle Bin`];
  if (skipped) parts.push(`${skipped} skipped`);
  if (notAttempted) parts.push(`${notAttempted} not started`);
  return { id: "op-" + Date.now(), title: plan.title, startedAt, finishedAt: now(), outcomes, cancelled: opCancelled && notAttempted > 0, summary: parts.join(", "), bytesMoved };
}

// MARK: Assistant

let aiRemaining = 25;
function aiAnswer(question: string): string {
  const q = question.toLowerCase();
  if (q.includes("node_modules") || q.includes("target") || q.includes("build"))
    return "Those are build folders. **node_modules** holds packages a project installed, and **target** holds Rust build output. Both come back when you run `npm install` or `cargo build`, so they're safe to remove from projects you aren't working on right now. Your quiet projects (old-blog, tiny-rust) have about 4 GB of them.";
  if (q.includes("temp"))
    return "The Temp folder is scratch space for Windows and apps. Files older than a day are almost always left over. MacMint skips anything an app still has open, so it's one of the safest places to clear.";
  if (q.includes("recycle") || q.includes("space") || q.includes("free"))
    return "Moving items to the Recycle Bin doesn't free space yet. Windows keeps them so you can restore them. Space comes back after you empty the Recycle Bin. Right now it holds about 3 GB.";
  if (q.includes("chrome") || q.includes("browser"))
    return "Chrome's cache is saved copies of websites. It's safe to clear, but Chrome has to be closed first. Websites may load a little slower the first time after.";
  return "From the last Smart Scan, most of your reclaimable space is in caches (about 6 GB) and build folders in projects you haven't opened in a while (about 9 GB). Both rebuild on their own. Your biggest single file is a 21 GB virtual machine disk in VirtualBox VMs. Only you know if you still need it.";
}

// MARK: Commands

type Handler = (args: Record<string, any>) => unknown | Promise<unknown>;

const handlers: Record<string, Handler> = {
  app_info: async () => { await sleep(150); return { version: "1.0.0", build: 100, platform: "Windows 11 Home 24H2 (x64)", dataFolder: ROAMING + "\\MacMint" } satisfies T.AppInfo; },
  get_overview: async () => {
    await sleep(600);
    return {
      computerName: "ALEX-LAPTOP", osVersion: "Windows 11 Home 24H2",
      disks: [
        { name: "Windows", mount: "C:\\", total: C_TOTAL, free: cFree, isSystem: true },
        { name: "Data", mount: "D:\\", total: 931 * GB, free: 512 * GB, isSystem: false },
      ],
      memory: { total: 16 * GB, used: 10.6 * GB }, cpuPercent: 23, uptimeSeconds: 3 * DAY + 4 * 3600 + 12 * 60,
      recycleBin, lastSmartScan: lastScan,
    } satisfies T.Overview;
  },
  run_smart_scan: async () => {
    scanCancelled = false;
    for (let i = 0; i < AREAS.length; i++) {
      emit("scan-progress", { area: AREAS[i].title, message: `Checking ${AREAS[i].title.toLowerCase()}…`, fraction: i / AREAS.length } satisfies T.ScanProgress);
      await sleep(520);
      if (scanCancelled) return fail("Scan cancelled. Nothing was changed.");
    }
    emit("scan-progress", { area: "Done", message: "Putting results together…", fraction: 1 } satisfies T.ScanProgress);
    await sleep(200);
    lastScan = buildSmartScan(now());
    return lastScan;
  },
  cancel_scan: () => { scanCancelled = true; },
  scan_cleanup: async () => {
    await sleep(900);
    return { checkedAt: now(), recycleBin, issues: [{ area: "Temporary files", path: "C:\\Windows\\Temp", message: "Needs an administrator to change. It was measured but can't be cleaned from here." }],
      groups: cleanupGroups.map((g) => ({ ...g, items: present(g.items) })).filter((g) => g.items.length) } satisfies T.CleanupScan;
  },
  scan_developer: async () => {
    await sleep(1000);
    return { checkedAt: now(), items: present(developerItems), caches: present(developerCaches),
      issues: [{ area: "Projects", path: HOME + "\\Projects\\keep-me", message: "Skipped because it's on your exclusions list." }] } satisfies T.DeveloperScan;
  },
  list_apps: async () => { await sleep(700); return apps; },
  uninstall_app: async ({ id }) => {
    await sleep(800);
    const a = apps.find((x) => x.id === id);
    if (!a) return fail("That app isn't installed any more.");
    if (!a.canUninstall) return fail(`${a.name} is part of Windows and can't be uninstalled here.`);
    apps = apps.filter((x) => x.id !== id);
    return `${a.name}'s own uninstaller opened. Follow its steps, then come back to check for leftovers.`;
  },
  find_leftovers: async ({ id }) => {
    await sleep(700);
    const a = apps.find((x) => x.id === id) ?? { name: id, id };
    const folder = a.name.split(" ")[0];
    const list = [
      cand({ id: `lo-${id}-roaming`, name: folder + " settings", path: `${ROAMING}\\${folder}`, bytes: (hash(id) % 40 + 4) * MB, category: "leftover", risk: "review", selected: false, group: "Roaming",
        detail: "Settings and sign-in", reason: `Looks like ${a.name}'s settings. Remove only if you won't use it again.` }),
      cand({ id: `lo-${id}-local`, name: folder + " data", path: `${LOCAL}\\${folder}\\User Data`, bytes: (hash(id + "l") % 400 + 60) * MB, category: "leftover", risk: "review", selected: false, group: "Local",
        detail: "Caches and local data", reason: `Data ${a.name} keeps on this PC.` }),
    ].filter((c) => !moved.has(c.id));
    register(list);
    return list;
  },
  list_startup: async () => { await sleep(600); return startup; },
  set_startup_enabled: async ({ id, enabled }) => {
    await sleep(300);
    const item = startup.find((s) => s.id === id);
    if (!item) return fail("That startup item is gone.");
    if (!item.canToggle) return fail("This one starts for everyone on this PC. Use Task Manager to change it.");
    const next = { ...item, enabled };
    startup = startup.map((s) => (s.id === id ? next : s));
    return next;
  },
  open_task_manager_startup: async () => { await sleep(200); },
  storage_breakdown: async ({ path }) => { await sleep(650); return breakdown(path ?? "C:\\"); },
  large_files: async ({ minBytes }) => {
    await sleep(1100);
    if (modes.has("errors")) return fail("Some folders couldn't be read right now. Windows said access is denied.");
    return { value: present(largeFiles).filter((f) => f.bytes >= minBytes).sort((a, b) => b.bytes - a.bytes),
      issues: [{ area: "Large Files", path: "C:\\Users\\Alex\\AppData\\Local\\Packages", message: "Some app folders can't be read without an administrator." }], cancelled: false } satisfies T.ScanReport<T.Candidate[]>;
  },
  find_duplicates: async () => {
    await sleep(1300);
    return { value: duplicateGroups.map((g) => ({ ...g, files: present(g.files) })).filter((g) => g.files.length > 1), issues: [], cancelled: false } satisfies T.ScanReport<T.DuplicateGroup[]>;
  },
  old_downloads: async () => { await sleep(800); return { value: present(oldDownloads), issues: [], cancelled: false } satisfies T.ScanReport<T.Candidate[]>; },
  performance: async () => {
    await sleep(400);
    const jitter = (v: number) => Math.max(0, +(v * (0.85 + Math.random() * 0.3)).toFixed(1));
    const list = processes.map((p) => ({ ...p, cpuPercent: p.lowered ? jitter(p.cpuPercent * 0.6) : jitter(p.cpuPercent) }));
    return { cpuPercent: Math.round(20 + Math.random() * 18), memory: { total: 16 * GB, used: 10.4 * GB + Math.random() * 0.6 * GB },
      processes: list, startupEnabled: startup.filter((s) => s.enabled).length, uptimeSeconds: 3 * DAY + 4 * 3600 + 12 * 60 } satisfies T.Performance;
  },
  set_low_priority: async ({ pid, low }) => {
    await sleep(300);
    const p = processes.find((x) => x.pid === pid);
    if (!p) return fail("That app has closed.");
    if (!p.canLower) return fail("Windows protects this one, so its priority can't change.");
    p.lowered = low;
    return { ...p };
  },
  prepare_plan: async ({ title, ids }) => { await sleep(600); return preparePlan(title, ids); },
  run_plan: ({ planId }) => runPlan(planId),
  cancel_operation: () => { opCancelled = true; },
  history: async () => { await sleep(500); return history; },
  restore: async ({ entryId, originalPath }) => {
    await sleep(700);
    const entry = history.find((h) => h.id === entryId);
    const receipt = entry?.receipts.find((r) => r.originalPath === originalPath);
    if (!entry || !receipt) return fail("That receipt couldn't be found.");
    if (receipt.restored) return fail("This item was already restored.");
    receipt.restored = true;
    history = history.map((h) => (h.id === entryId ? { ...h, receipts: h.receipts.map((r) => (r === receipt ? { ...r } : r)) } : h));
    for (const c of registry.values()) if (c.path === originalPath) moved.delete(c.id);
    recycleBin = { bytes: Math.max(0, recycleBin.bytes - receipt.bytes), items: Math.max(0, recycleBin.items - 1) };
    if (lastScan) lastScan = buildSmartScan(lastScan.checkedAt);
    return `Put back in ${originalPath.split("\\").slice(0, -1).join("\\")}.`;
  },
  empty_recycle_bin: async () => {
    await sleep(900);
    const freed = recycleBin.bytes;
    cFree += freed;
    recycleBin = { bytes: 0, items: 0 };
    history = history.map((h) => ({ ...h }));
    if (lastScan) lastScan = buildSmartScan(lastScan.checkedAt);
    return `The Recycle Bin is empty. About ${(freed / GB).toFixed(1)} GB is free again.`;
  },
  get_settings: async () => { await sleep(120); return settings; },
  save_settings: async (args) => { await sleep(200); settings = { ...args.settings }; return settings; },
  account_status: async () => { await sleep(300); return account; },
  sign_in: async ({ email, password }) => {
    await sleep(900);
    if (!String(email).includes("@") || String(password).length < 4) return fail("That email and password don't match. Check them and try again.");
    account = { ...signedIn, email, name: "Alex Rivera" };
    return account;
  },
  sign_out: async () => { await sleep(500); account = { ...signedOut }; return account; },
  refresh_account: async () => { await sleep(700); return account; },
  ai_ask: async ({ question }) => {
    await sleep(1400);
    if (!settings.aiEnabled) return fail("Turn on MacMint AI first.");
    if (!account.aiAvailable) return fail("MacMint AI isn't available right now.");
    aiRemaining = Math.max(0, aiRemaining - 1);
    return { answer: aiAnswer(String(question)), remaining: aiRemaining } satisfies T.AIAnswer;
  },
  check_updates: async () => {
    await sleep(900);
    return { current: "1.0.0", build: 100, latest: "1.1.0", latestBuild: 112, available: true,
      notes: "Faster Storage maps on big drives. Clearer names for startup apps.", publishedAt: "2026-11-02", message: null } satisfies T.UpdateInfo;
  },
  install_update: async () => { await sleep(900); return "Downloading MacMint 1.1.0. The installer starts when it's ready, and MacMint closes."; },
  reveal_path: async () => { await sleep(100); },
  open_url: async () => { await sleep(100); },
};

export async function mockInvoke(name: string, args: Record<string, any>): Promise<unknown> {
  const handler = handlers[name];
  if (!handler) return fail(`The command "${name}" isn't available.`);
  // Hand out copies so the UI can never change the mock's state by accident.
  const result = await handler(args);
  return result === undefined ? undefined : JSON.parse(JSON.stringify(result));
}
