//! Finds cleanup targets in places whose owner is known: Windows temp, browser and app caches,
//! crash reports, developer tool caches and old installers in Downloads. A cache whose app is
//! open is listed but never preselected; unknown owners and anything that can't be recreated are
//! review-only.
use crate::fs::{is_link, measure, modified_secs, now_secs};
use crate::model::{Candidate, CleanupCategory, CleanupTarget, Found, Risk, ScanIssue};
use crate::paths::KnownFolders;
use crate::plan::PlanItem;
use crate::process::ActiveProcess;
use crate::safety::{SafetyPolicy, CACHE_FOLDER_NAMES};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

const DAY: u64 = 86_400;

/// A known app whose cache folders can be recreated.
struct AppRule {
    name: &'static str,
    processes: &'static [&'static str],
    /// Relative to Local (L) or Roaming (R) app data.
    base: char,
    folder: &'static str,
    layout: Layout,
    risk: Risk,
}

#[derive(Clone, Copy)]
enum Layout {
    /// Chromium "User Data": every profile folder (Default, Profile 1…) and the top level.
    ChromiumUserData,
    /// Firefox: every profile under Profiles/.
    FirefoxProfiles,
    /// An Electron app: cache folders directly in its data folder.
    Electron,
    /// The folder itself is a cache.
    Whole,
}

const APP_RULES: &[AppRule] = &[
    AppRule { name: "Google Chrome", processes: &["chrome.exe"], base: 'L', folder: "Google/Chrome/User Data", layout: Layout::ChromiumUserData, risk: Risk::Safe },
    AppRule { name: "Microsoft Edge", processes: &["msedge.exe"], base: 'L', folder: "Microsoft/Edge/User Data", layout: Layout::ChromiumUserData, risk: Risk::Safe },
    // Brave is never treated as generic junk: listed for review only.
    AppRule { name: "Brave", processes: &["brave.exe"], base: 'L', folder: "BraveSoftware/Brave-Browser/User Data", layout: Layout::ChromiumUserData, risk: Risk::Review },
    AppRule { name: "Vivaldi", processes: &["vivaldi.exe"], base: 'L', folder: "Vivaldi/User Data", layout: Layout::ChromiumUserData, risk: Risk::Safe },
    AppRule { name: "Opera", processes: &["opera.exe"], base: 'L', folder: "Opera Software/Opera Stable", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Firefox", processes: &["firefox.exe"], base: 'L', folder: "Mozilla/Firefox/Profiles", layout: Layout::FirefoxProfiles, risk: Risk::Safe },
    AppRule { name: "Visual Studio Code", processes: &["code.exe"], base: 'R', folder: "Code", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "VS Code Insiders", processes: &["code - insiders.exe"], base: 'R', folder: "Code - Insiders", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Cursor", processes: &["cursor.exe"], base: 'R', folder: "Cursor", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Discord", processes: &["discord.exe"], base: 'R', folder: "discord", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Slack", processes: &["slack.exe"], base: 'R', folder: "Slack", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Notion", processes: &["notion.exe"], base: 'R', folder: "Notion", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Obsidian", processes: &["obsidian.exe"], base: 'R', folder: "obsidian", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Spotify", processes: &["spotify.exe"], base: 'L', folder: "Spotify", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "Claude", processes: &["claude.exe"], base: 'R', folder: "Claude", layout: Layout::Electron, risk: Risk::Safe },
    AppRule { name: "WebCatalog", processes: &["webcatalog.exe"], base: 'R', folder: "WebCatalog", layout: Layout::Electron, risk: Risk::Review },
    AppRule { name: "DirectX shader cache", processes: &[], base: 'L', folder: "D3DSCache", layout: Layout::Whole, risk: Risk::Safe },
    AppRule { name: "NVIDIA shader cache", processes: &[], base: 'L', folder: "NVIDIA/DXCache", layout: Layout::Whole, risk: Risk::Safe },
    AppRule { name: "NVIDIA OpenGL cache", processes: &[], base: 'L', folder: "NVIDIA/GLCache", layout: Layout::Whole, risk: Risk::Safe },
    AppRule { name: "AMD shader cache", processes: &[], base: 'L', folder: "AMD/DxCache", layout: Layout::Whole, risk: Risk::Safe },
    AppRule { name: "AMD shader cache", processes: &[], base: 'L', folder: "AMD/DxcCache", layout: Layout::Whole, risk: Risk::Safe },
    AppRule { name: "AMD Vulkan cache", processes: &[], base: 'L', folder: "AMD/VkCache", layout: Layout::Whole, risk: Risk::Safe },
];

/// Developer tool caches: downloads the tool fetches again when needed.
struct ToolRule {
    name: &'static str,
    processes: &'static [&'static str],
    base: char, // L = Local app data, H = home
    folder: &'static str,
    risk: Risk,
    detail: &'static str,
}

const TOOL_RULES: &[ToolRule] = &[
    ToolRule { name: "npm", processes: &["node.exe", "npm.exe"], base: 'L', folder: "npm-cache/_cacache", risk: Risk::Safe, detail: "npm's download cache. Packages download again when needed." },
    ToolRule { name: "pip", processes: &["python.exe", "pip.exe", "py.exe"], base: 'L', folder: "pip/Cache", risk: Risk::Safe, detail: "pip's download cache. Packages download again when needed." },
    ToolRule { name: "Yarn", processes: &["node.exe", "yarn.exe"], base: 'L', folder: "Yarn/Cache", risk: Risk::Safe, detail: "Yarn's download cache." },
    ToolRule { name: "pnpm", processes: &["node.exe", "pnpm.exe"], base: 'L', folder: "pnpm/store", risk: Risk::Review, detail: "pnpm's package store. Projects link to it, so they need a reinstall afterwards." },
    ToolRule { name: "NuGet", processes: &["dotnet.exe", "msbuild.exe", "devenv.exe"], base: 'L', folder: "NuGet/v3-cache", risk: Risk::Safe, detail: "NuGet's download cache." },
    ToolRule { name: "Go", processes: &["go.exe"], base: 'L', folder: "go-build", risk: Risk::Safe, detail: "Go's build cache. Builds are slower once, then fast again." },
    ToolRule { name: "Gradle", processes: &["java.exe", "gradle.exe"], base: 'H', folder: ".gradle/caches", risk: Risk::Safe, detail: "Gradle's download and build cache." },
    ToolRule { name: "Cargo", processes: &["cargo.exe", "rustc.exe"], base: 'H', folder: ".cargo/registry/cache", risk: Risk::Safe, detail: "Downloaded Rust crates. They download again when needed." },
    ToolRule { name: "Visual Studio", processes: &["devenv.exe", "setup.exe", "vs_installer.exe"], base: 'L', folder: "Microsoft/VisualStudio/Packages/_Instances", risk: Risk::Review, detail: "Visual Studio's installer packages. Repairing or changing Visual Studio may need them again." },
];

pub struct CleanupScanResult {
    pub found: Vec<Found>,
    pub issues: Vec<ScanIssue>,
    pub cancelled: bool,
}

fn base(folders: &KnownFolders, b: char) -> &Path {
    match b {
        'R' => &folders.roaming_app_data,
        'H' => &folders.home,
        _ => &folders.local_app_data,
    }
}

fn running_owner(processes: &[ActiveProcess], owners: &[&str]) -> bool {
    processes.iter().any(|p| owners.iter().any(|o| p.name.eq_ignore_ascii_case(o)))
}

fn is_cache_name(name: &str) -> bool {
    CACHE_FOLDER_NAMES.iter().any(|n| n.eq_ignore_ascii_case(name))
}

fn children(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).map(|r| r.flatten().map(|e| e.path()).collect()).unwrap_or_default()
}

/// Cache folders for one app rule.
fn app_cache_folders(root: &Path, layout: Layout) -> Vec<PathBuf> {
    let mut out = Vec::new();
    match layout {
        Layout::Whole => {
            if root.is_dir() {
                out.push(root.to_path_buf());
            }
        }
        Layout::Electron => {
            for c in children(root) {
                if c.is_dir() && c.file_name().map(|n| is_cache_name(&n.to_string_lossy())).unwrap_or(false) {
                    out.push(c);
                }
            }
            // VS Code keeps cached data per version; the newest is the one in use.
            let cached = root.join("CachedData");
            if cached.is_dir() {
                out.retain(|p| p != &cached);
                let mut versions: Vec<_> = children(&cached).into_iter().filter(|p| p.is_dir()).collect();
                versions.sort_by_key(|p| modified_secs(p).unwrap_or(0));
                versions.pop();
                out.extend(versions);
            }
        }
        Layout::ChromiumUserData => {
            for c in children(root) {
                if !c.is_dir() {
                    continue;
                }
                let name = c.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                if is_cache_name(&name) {
                    out.push(c.clone());
                } else if c.join("Preferences").is_file() {
                    for inner in children(&c) {
                        if inner.is_dir() && inner.file_name().map(|n| is_cache_name(&n.to_string_lossy())).unwrap_or(false) {
                            out.push(inner);
                        }
                    }
                }
            }
        }
        Layout::FirefoxProfiles => {
            for profile in children(root) {
                for name in ["cache2", "startupCache"] {
                    let p = profile.join(name);
                    if p.is_dir() {
                        out.push(p);
                    }
                }
            }
        }
    }
    out.retain(|p| !is_link(p));
    out
}

fn profile_label(path: &Path) -> String {
    let parent = path.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    if parent.eq_ignore_ascii_case("User Data") || parent.is_empty() { name } else { format!("{name} · {parent}") }
}

struct Ctx<'a> {
    policy: &'a SafetyPolicy,
    processes: &'a [ActiveProcess],
    excluded: &'a [PathBuf],
    found: Vec<Found>,
    issues: Vec<ScanIssue>,
}

impl Ctx<'_> {
    #[allow(clippy::too_many_arguments)]
    fn add(&mut self, category: CleanupCategory, path: PathBuf, name: String, group: &str, detail: String, risk: Risk, reason: &str, owners: &[&str], owner_name: Option<&str>, min_bytes: u64) {
        if self.excluded.iter().any(|x| crate::fs::is_inside_or_equal(&path, x) || crate::fs::is_inside_or_equal(x, &path)) {
            return;
        }
        if !self.policy.cleanup(&path, category).allowed() {
            return;
        }
        let m = measure(&path, self.excluded);
        if m.bytes < min_bytes {
            return;
        }
        let open = !owners.is_empty() && running_owner(self.processes, owners);
        let blocked_by = open.then(|| format!("{} is open. Close it first to clean this.", owner_name.unwrap_or("Its app")));
        let target = CleanupTarget {
            id: crate::model::path_id(&path),
            category,
            name: name.clone(),
            detail: detail.clone(),
            bytes: m.bytes,
            risk,
            reason: reason.into(),
            selected: risk == Risk::Safe && !open,
            owner_processes: Some(owners.iter().map(|s| s.to_string()).collect()),
            owner_name: owner_name.map(String::from),
            modified: modified_secs(&path),
            path: path.clone(),
        };
        let item = PlanItem::cleanup(&target);
        let mut detail = detail;
        if m.unreadable > 0 {
            detail.push_str(&format!(" Some of it ({} items) couldn't be read and will be left.", m.unreadable));
        }
        self.found.push(Found {
            candidate: Candidate {
                id: target.id,
                path,
                name,
                group: group.into(),
                detail,
                bytes: m.bytes,
                risk,
                reason: reason.into(),
                selected: target.selected,
                blocked_by,
                owner_name: target.owner_name,
                modified: target.modified,
                category: category.key().into(),
            },
            item,
        });
    }
}

/// Runs every cleanup rule. `processes` is one reading of what's running, used to mark open apps.
pub fn scan(policy: &SafetyPolicy, processes: &[ActiveProcess], excluded: &[PathBuf], cancel: &AtomicBool) -> CleanupScanResult {
    let f = policy.folders().clone();
    let now = now_secs();
    let mut ctx = Ctx { policy, processes, excluded, found: vec![], issues: vec![] };

    // Temporary files: anything in Temp untouched for a day.
    match std::fs::read_dir(&f.temp) {
        Ok(entries) => {
            for e in entries.flatten() {
                if cancel.load(Ordering::Relaxed) {
                    return CleanupScanResult { found: ctx.found, issues: ctx.issues, cancelled: true };
                }
                let p = e.path();
                if is_link(&p) {
                    continue;
                }
                let recent = newest_change(&p, 400).map(|t| now.saturating_sub(t) < DAY).unwrap_or(true);
                if recent {
                    continue;
                }
                let name = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                ctx.add(CleanupCategory::TempFiles, p, name, "Temp", "Left behind by installers and apps. Unchanged for over a day.".into(), Risk::Safe, "Temporary files are made to be thrown away. Anything still in use is skipped.", &[], None, 1);
            }
        }
        Err(e) => ctx.issues.push(ScanIssue::new("Temporary files", Some(&f.temp), format!("Couldn't open Temp: {e}"))),
    }

    // App caches with a known owner.
    for rule in APP_RULES {
        if cancel.load(Ordering::Relaxed) {
            return CleanupScanResult { found: ctx.found, issues: ctx.issues, cancelled: true };
        }
        let root = base(&f, rule.base).join(rule.folder);
        for cache in app_cache_folders(&root, rule.layout) {
            let label = match rule.layout {
                Layout::Whole => rule.name.to_string(),
                _ => profile_label(&cache),
            };
            let (detail, reason) = if rule.risk == Risk::Safe {
                (format!("{} cache. It rebuilds itself as you use the app.", rule.name), "Cache files are copies the app makes again when it needs them. Skipped while the app is open.")
            } else {
                (format!("{} cache. Listed for you to decide; MacMint doesn't pick it for you.", rule.name), "MacMint doesn't clean this app's data on its own.")
            };
            ctx.add(CleanupCategory::AppCaches, cache, label, rule.name, detail, rule.risk, reason, rule.processes, Some(rule.name), 1_000_000);
        }
    }

    // Other apps' caches: the owner isn't known, so review only.
    let known_roots: Vec<PathBuf> = APP_RULES.iter().map(|r| base(&f, r.base).join(r.folder.split('/').next().unwrap_or(r.folder))).collect();
    for root in [&f.local_app_data, &f.roaming_app_data] {
        for app in children(root) {
            if !app.is_dir() || is_link(&app) || known_roots.iter().any(|k| crate::fs::comparison_key(k) == crate::fs::comparison_key(&app)) {
                continue;
            }
            let app_name = app.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if ["microsoft", "packages", "temp", "macmint", "programs", "google", "mozilla"].contains(&app_name.to_lowercase().as_str()) {
                continue;
            }
            for cache in app_cache_folders(&app, Layout::Electron) {
                ctx.add(CleanupCategory::AppCaches, cache.clone(), format!("{} · {}", app_name, cache.file_name().unwrap().to_string_lossy()), &app_name, format!("A cache inside {app_name}. MacMint couldn't confirm which app owns it."), Risk::Review, "Ownership couldn't be confirmed, so it's left for you to review.", &[], None, 5_000_000);
            }
        }
    }

    // Crash reports: useful for troubleshooting, so review.
    let crash = f.local_app_data.join("CrashDumps");
    for d in children(&crash) {
        let name = d.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        ctx.add(CleanupCategory::LogsAndReports, d, name, "Crash dumps", "A memory dump saved when an app crashed.".into(), Risk::Review, "Only needed if you're troubleshooting that crash.", &[], None, 1);
    }
    for sub in ["ReportArchive", "ReportQueue"] {
        let dir = f.local_app_data.join("Microsoft/Windows/WER").join(sub);
        for d in children(&dir) {
            let name = d.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            ctx.add(CleanupCategory::LogsAndReports, d, name, "Error reports", "A Windows error report.".into(), Risk::Review, "Old error reports. Windows doesn't need them once they're sent.", &[], None, 1);
        }
    }

    // Developer tool caches.
    for rule in TOOL_RULES {
        let p = base(&f, rule.base).join(rule.folder);
        if p.is_dir() && !is_link(&p) {
            let reason = if rule.risk == Risk::Safe { "The tool downloads these again when it needs them. Skipped while the tool is running." } else { "Removing this has side effects, so it's left for you to decide." };
            ctx.add(CleanupCategory::DeveloperCaches, p, format!("{} cache", rule.name), rule.name, rule.detail.into(), rule.risk, reason, rule.processes, Some(rule.name), 5_000_000);
        }
    }

    // Old installers in Downloads.
    for p in children(&f.downloads) {
        if !p.is_file() || !crate::safety::is_installer_name(&p) {
            continue;
        }
        let age = modified_secs(&p).map(|t| now.saturating_sub(t) / DAY).unwrap_or(0);
        if age < 30 {
            continue;
        }
        let name = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        ctx.add(CleanupCategory::Installers, p, name, "Downloads", format!("Downloaded {age} days ago."), Risk::Review, "Installers and archives are usually not needed after setup. Check you don't need this copy.", &[], None, 1);
    }

    let Ctx { found, issues, .. } = ctx;
    CleanupScanResult { found, issues, cancelled: false }
}

/// The newest change time inside `path`, looking at no more than `limit` entries.
pub fn newest_change(path: &Path, limit: usize) -> Option<u64> {
    let mut newest = modified_secs(path)?;
    if path.is_dir() {
        for e in walkdir::WalkDir::new(path).follow_links(false).into_iter().flatten().take(limit) {
            if let Some(t) = e.metadata().ok().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()) {
                newest = newest.max(t.as_secs());
            }
        }
    }
    Some(newest)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, bytes: usize) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, vec![7u8; bytes]).unwrap();
    }

    fn age(path: &Path, days: u64) {
        let t = std::time::SystemTime::now() - std::time::Duration::from_secs(days * DAY);
        let f = std::fs::File::options().write(true).open(path).or_else(|_| std::fs::File::open(path)).unwrap();
        f.set_modified(t).unwrap();
    }

    #[test]
    fn finds_known_caches_and_respects_open_apps_and_profile_data() {
        let dir = tempfile::tempdir().unwrap();
        let f = KnownFolders::under(dir.path());
        let ud = f.local_app_data.join("Google/Chrome/User Data");
        write(&ud.join("Default/Preferences"), 10);
        write(&ud.join("Default/Cache/Cache_Data/f"), 2_000_000);
        write(&ud.join("Default/Network/Cookies"), 2_000_000);
        write(&ud.join("Default/Local Storage/x"), 2_000_000);
        write(&f.roaming_app_data.join("Code/Cache/x"), 2_000_000);
        write(&f.roaming_app_data.join("Code/User/settings.json"), 2_000_000);
        write(&f.roaming_app_data.join("Mystery/GPUCache/x"), 6_000_000);
        let policy = SafetyPolicy::new(f.clone());
        let procs = vec![ActiveProcess { pid: 1, name: "code.exe".into(), working_directory: None, exe: None }];
        let r = scan(&policy, &procs, &[], &AtomicBool::new(false));
        let by = |s: &str| r.found.iter().find(|x| x.candidate.path.to_string_lossy().replace('\\', "/").contains(s)).map(|x| x.candidate.clone());
        let chrome = by("Default/Cache").expect("chrome cache");
        assert!(chrome.selected && chrome.risk == Risk::Safe);
        let code = by("Code/Cache").expect("vscode cache");
        assert!(!code.selected && code.blocked_by.is_some(), "open owner is never preselected");
        let mystery = by("Mystery/GPUCache").expect("unknown owner");
        assert_eq!(mystery.risk, Risk::Review);
        assert!(!mystery.selected);
        assert!(by("Network").is_none() && by("Local Storage").is_none() && by("Code/User").is_none());
    }

    #[test]
    fn temp_needs_a_day_and_installers_a_month() {
        let dir = tempfile::tempdir().unwrap();
        let f = KnownFolders::under(dir.path());
        write(&f.temp.join("old.tmp"), 10);
        age(&f.temp.join("old.tmp"), 3);
        write(&f.temp.join("new.tmp"), 10);
        write(&f.downloads.join("setup.exe"), 10);
        age(&f.downloads.join("setup.exe"), 60);
        write(&f.downloads.join("fresh.msi"), 10);
        write(&f.downloads.join("report.pdf"), 10);
        age(&f.downloads.join("report.pdf"), 90);
        let r = scan(&SafetyPolicy::new(f), &[], &[], &AtomicBool::new(false));
        let names: Vec<_> = r.found.iter().map(|x| x.candidate.name.clone()).collect();
        assert!(names.contains(&"old.tmp".to_string()));
        assert!(!names.contains(&"new.tmp".to_string()));
        assert!(names.contains(&"setup.exe".to_string()));
        assert!(!names.contains(&"fresh.msi".to_string()) && !names.contains(&"report.pdf".to_string()));
        let setup = r.found.iter().find(|x| x.candidate.name == "setup.exe").unwrap();
        assert!(!setup.candidate.selected);
    }

    #[test]
    fn every_found_item_passes_the_move_check() {
        let dir = tempfile::tempdir().unwrap();
        let f = KnownFolders::under(dir.path());
        write(&f.local_app_data.join("npm-cache/_cacache/index-v5/x"), 6_000_000);
        write(&f.local_app_data.join("CrashDumps/app.exe.123.dmp"), 10);
        let policy = SafetyPolicy::new(f);
        let r = scan(&policy, &[], &[], &AtomicBool::new(false));
        assert_eq!(r.found.len(), 2);
        for x in &r.found {
            let crate::plan::ItemKind::Cleanup { category, .. } = x.item.kind else { panic!() };
            assert!(policy.cleanup(&x.item.path, category).allowed(), "{:?}", x.item.path);
        }
    }
}
