//! Installed apps from the Windows uninstall list, uninstalling through each app's own
//! uninstaller, and AppData folders that no installed app seems to own.
use crate::fs::{is_link, measure, modified_secs, now_secs};
use crate::model::{Candidate, Found, Risk, ScanIssue};
use crate::plan::{ItemKind, PlanItem};
use crate::process::ActiveProcess;
use crate::safety::SafetyPolicy;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledApp {
    pub id: String,
    pub name: String,
    pub publisher: Option<String>,
    pub version: Option<String>,
    pub bytes: Option<u64>,
    pub install_date: Option<String>,
    pub location: Option<String>,
    pub icon: Option<String>,
    pub can_uninstall: bool,
    pub running: bool,
    pub scope: String,
    #[serde(skip)]
    pub uninstall_command: Option<String>,
}

/// Splits a registry command line into program and arguments. MSI "install/repair" switches
/// become "uninstall" so the Windows Installer shows its uninstall dialog.
pub fn split_command(command: &str) -> Option<(String, String)> {
    let c = command.trim();
    if c.is_empty() {
        return None;
    }
    let (program, args) = if let Some(rest) = c.strip_prefix('"') {
        let end = rest.find('"')?;
        (rest[..end].to_string(), rest[end + 1..].trim().to_string())
    } else {
        let lower = c.to_lowercase();
        match lower.find(".exe") {
            Some(i) => (c[..i + 4].to_string(), c[i + 4..].trim().to_string()),
            None => match c.find(' ') {
                Some(i) => (c[..i].to_string(), c[i + 1..].trim().to_string()),
                None => (c.to_string(), String::new()),
            },
        }
    };
    let is_msi = Path::new(&program).file_name().map(|n| n.to_string_lossy().eq_ignore_ascii_case("msiexec.exe") || n.to_string_lossy().eq_ignore_ascii_case("msiexec")).unwrap_or(false);
    let args = if is_msi {
        let a = args.replace("/I{", "/X{").replace("/i{", "/X{").replace("/I {", "/X {");
        if a.to_uppercase().contains("/X") { a } else { format!("/X {a}") }
    } else {
        args
    };
    Some((program, args))
}

fn normalized(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_alphanumeric()).collect::<String>().to_lowercase()
}

/// Whether an AppData folder name plausibly belongs to an installed app.
fn matches_app(folder: &str, apps: &[InstalledApp]) -> bool {
    let f = normalized(folder);
    if f.len() < 3 {
        return true;
    }
    apps.iter().any(|a| {
        let name = normalized(&a.name);
        let first = normalized(a.name.split_whitespace().next().unwrap_or(""));
        let publisher = a.publisher.as_deref().map(normalized).unwrap_or_default();
        let loc = a.location.as_deref().and_then(|l| Path::new(l.trim_end_matches(['\\', '/'])).file_name().map(|n| normalized(&n.to_string_lossy()))).unwrap_or_default();
        (!name.is_empty() && (name.contains(&f) || f.contains(&name)))
            || (first.len() >= 4 && (f.contains(&first) || first.contains(&f)))
            || (publisher.len() >= 4 && (publisher.contains(&f) || f.contains(&publisher)))
            || (!loc.is_empty() && loc == f)
    })
}

/// Names in AppData that belong to Windows itself or to very common shared runtimes.
const SYSTEM_APPDATA: &[&str] = &[
    "microsoft", "packages", "temp", "programs", "macmint", "co.macmint.windows", "comms", "connecteddevicesplatform", "crashdumps",
    "d3dscache", "microsoft_corporation", "publishers", "virtualstore", "fontcache", "history", "tempstate",
    "squirreltemp", "elevateddiagnostics", "peerdistrepub", "placeholdertilelogofolder", "identities",
    "adobe", "apple", "apple computer", "intel", "nvidia", "nvidia corporation", "amd", "realtek", "npm", "npm-cache",
    "pip", "yarn", "pnpm", "nuget", "go-build", "jedi", "code", "github", "google", "mozilla", "python", "java",
];

/// AppData folders that no installed app seems to own. Review only, never preselected; skipped
/// entirely when the app list couldn't be read, so a failure never makes data look ownerless.
pub fn leftovers(policy: &SafetyPolicy, apps: &[InstalledApp], inventory_complete: bool, processes: &[ActiveProcess], excluded: &[PathBuf]) -> (Vec<Found>, Vec<ScanIssue>) {
    let mut found = Vec::new();
    let mut issues = Vec::new();
    if !inventory_complete {
        issues.push(ScanIssue::new("Leftovers", None, "The list of installed apps couldn't be read completely, so no folder is marked as unowned."));
        return (found, issues);
    }
    let f = policy.folders();
    let now = now_secs();
    for root in [&f.local_app_data, &f.roaming_app_data] {
        let Ok(entries) = std::fs::read_dir(root) else {
            issues.push(ScanIssue::new("Leftovers", Some(root), "Couldn't open this folder."));
            continue;
        };
        for e in entries.flatten() {
            let p = e.path();
            if !p.is_dir() || is_link(&p) {
                continue;
            }
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || SYSTEM_APPDATA.contains(&name.to_lowercase().as_str()) || matches_app(&name, apps) {
                continue;
            }
            if excluded.iter().any(|x| crate::fs::is_inside_or_equal(&p, x)) || !policy.app_leftover(&p).allowed() {
                continue;
            }
            let lname = name.to_lowercase();
            if processes.iter().any(|pr| pr.name.trim_end_matches(".exe").contains(&lname) || pr.exe.as_deref().map(|x| crate::fs::is_inside_or_equal(x, &p)).unwrap_or(false)) {
                continue;
            }
            let recent = crate::cleanup::newest_change(&p, 300).map(|t| now.saturating_sub(t) < 30 * 86_400).unwrap_or(true);
            if recent {
                continue;
            }
            let m = measure(&p, excluded);
            if m.bytes < 1_000_000 {
                continue;
            }
            let id = crate::model::path_id(&p);
            let reason = "No installed app matched this folder. It may belong to an app you removed, or to a portable app. Check before removing.";
            found.push(Found {
                candidate: Candidate {
                    id: id.clone(),
                    path: p.clone(),
                    name: name.clone(),
                    group: if *root == f.roaming_app_data { "AppData\\Roaming".into() } else { "AppData\\Local".into() },
                    detail: "App data with no owner found. Unchanged for over 30 days.".into(),
                    bytes: m.bytes,
                    risk: Risk::Review,
                    reason: reason.into(),
                    selected: false,
                    blocked_by: None,
                    owner_name: None,
                    modified: modified_secs(&p),
                    category: "leftover".into(),
                },
                item: PlanItem {
                    id,
                    name,
                    identity: crate::fs::identity(&p),
                    path: p,
                    kind: ItemKind::AppLeftover,
                    expected_bytes: m.bytes,
                    reason: reason.into(),
                    source: "App data with no owner found".into(),
                    needs_attention: true,
                    owner_processes: vec![],
                    project_folder: None,
                },
            });
        }
    }
    found.sort_by(|a, b| b.candidate.bytes.cmp(&a.candidate.bytes));
    (found, issues)
}

/// Folders in AppData named after one app (for "Remove leftovers" after an uninstall).
pub fn leftovers_for(policy: &SafetyPolicy, app: &InstalledApp, excluded: &[PathBuf]) -> Vec<Found> {
    let f = policy.folders();
    let mut out = Vec::new();
    for root in [&f.local_app_data, &f.roaming_app_data] {
        for e in std::fs::read_dir(root).into_iter().flatten().flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if !p.is_dir() || is_link(&p) || SYSTEM_APPDATA.contains(&name.to_lowercase().as_str()) || !matches_app(&name, std::slice::from_ref(app)) {
                continue;
            }
            if !policy.app_leftover(&p).allowed() || excluded.iter().any(|x| crate::fs::is_inside_or_equal(&p, x)) {
                continue;
            }
            let m = measure(&p, excluded);
            let id = crate::model::path_id(&p);
            let reason = format!("Named like {}. Settings and data in here are gone for good once the Recycle Bin is emptied.", app.name);
            out.push(Found {
                candidate: Candidate { id: id.clone(), path: p.clone(), name: name.clone(), group: app.name.clone(), detail: "Possible leftover data".into(), bytes: m.bytes, risk: Risk::Review, reason: reason.clone(), selected: false, blocked_by: None, owner_name: Some(app.name.clone()), modified: modified_secs(&p), category: "leftover".into() },
                item: PlanItem { id, name, identity: crate::fs::identity(&p), path: p, kind: ItemKind::AppLeftover, expected_bytes: m.bytes, reason, source: format!("Leftovers of {}", app.name), needs_attention: true, owner_processes: vec![], project_folder: None },
            });
        }
    }
    out
}

/// Reads the uninstall list. The bool says whether every place was readable.
#[cfg(windows)]
pub fn installed_apps(processes: &[ActiveProcess]) -> (Vec<InstalledApp>, bool) {
    use winreg::enums::*;
    use winreg::RegKey;
    let places = [
        (HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "currentUser", "hkcu"),
        (HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "allUsers", "hklm"),
        (HKEY_LOCAL_MACHINE, "Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "allUsers", "hklm32"),
    ];
    let mut apps: Vec<InstalledApp> = Vec::new();
    let mut complete = true;
    for (hive, path, scope, tag) in places {
        let key = match RegKey::predef(hive).open_subkey_with_flags(path, KEY_READ) {
            Ok(k) => k,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => {
                complete = false;
                continue;
            }
        };
        for sub in key.enum_keys().flatten() {
            let Ok(k) = key.open_subkey_with_flags(&sub, KEY_READ) else { continue };
            let s = |n: &str| k.get_value::<String, _>(n).ok().filter(|v| !v.trim().is_empty());
            let d = |n: &str| k.get_value::<u32, _>(n).ok();
            let Some(name) = s("DisplayName") else { continue };
            if d("SystemComponent") == Some(1) || s("ParentKeyName").is_some() || s("ReleaseType").map(|r| r.contains("Update") || r.contains("Hotfix")).unwrap_or(false) {
                continue;
            }
            let uninstall = s("UninstallString");
            let location = s("InstallLocation");
            let running = location.as_deref().map(|l| {
                let lp = Path::new(l);
                l.len() > 3 && processes.iter().any(|p| p.exe.as_deref().map(|e| crate::fs::is_inside_or_equal(e, lp)).unwrap_or(false))
            }).unwrap_or(false);
            if apps.iter().any(|a| a.name == name && a.version == s("DisplayVersion")) {
                continue;
            }
            apps.push(InstalledApp {
                id: format!("{tag}:{sub}"),
                name,
                publisher: s("Publisher"),
                version: s("DisplayVersion"),
                bytes: d("EstimatedSize").map(|kb| kb as u64 * 1024),
                install_date: s("InstallDate").map(|v| if v.len() == 8 { format!("{}-{}-{}", &v[..4], &v[4..6], &v[6..]) } else { v }),
                location,
                icon: None,
                can_uninstall: uninstall.is_some() && d("NoRemove") != Some(1),
                running,
                scope: scope.into(),
                uninstall_command: uninstall,
            });
        }
    }
    apps.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    (apps, complete)
}

#[cfg(not(windows))]
pub fn installed_apps(_processes: &[ActiveProcess]) -> (Vec<InstalledApp>, bool) {
    (vec![], true)
}

/// Starts the app's own uninstaller (Windows asks for permission when it needs it).
#[cfg(windows)]
pub fn uninstall(app: &InstalledApp) -> Result<String, String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::ShellExecuteW;
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    if app.running {
        return Err(format!("{} is open. Close it first, then uninstall.", app.name));
    }
    let cmd = app.uninstall_command.as_deref().ok_or("This app doesn't offer an uninstaller.")?;
    let (program, args) = split_command(cmd).ok_or("This app's uninstaller couldn't be read.")?;
    let wide = |s: &str| std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect::<Vec<u16>>();
    let (verb, file, params) = (wide("open"), wide(&program), wide(&args));
    let r = unsafe { ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), file.as_ptr(), params.as_ptr(), std::ptr::null(), SW_SHOWNORMAL) };
    if (r as isize) > 32 {
        Ok(format!("{}'s uninstaller is open. Follow its steps; MacMint will refresh the list when you come back.", app.name))
    } else {
        Err(format!("Windows couldn't start {}'s uninstaller (code {}).", app.name, r as isize))
    }
}

#[cfg(not(windows))]
pub fn uninstall(_app: &InstalledApp) -> Result<String, String> {
    Err("Uninstalling is only available on Windows.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_quoted_unquoted_and_msi_commands() {
        assert_eq!(split_command(r#""C:\Program Files\App\unins000.exe" /SILENT"#).unwrap(), (r"C:\Program Files\App\unins000.exe".into(), "/SILENT".into()));
        assert_eq!(split_command(r"C:\Program Files\App\uninstall.exe --x").unwrap(), (r"C:\Program Files\App\uninstall.exe".into(), "--x".into()));
        assert_eq!(split_command("MsiExec.exe /I{1234-AB}").unwrap(), ("MsiExec.exe".into(), "/X{1234-AB}".into()));
        assert!(split_command("  ").is_none());
    }

    fn app(name: &str, publisher: &str) -> InstalledApp {
        InstalledApp { id: name.into(), name: name.into(), publisher: Some(publisher.into()), version: None, bytes: None, install_date: None, location: None, icon: None, can_uninstall: true, running: false, scope: "currentUser".into(), uninstall_command: None }
    }

    #[test]
    fn leftovers_skip_matched_recent_and_incomplete() {
        let dir = tempfile::tempdir().unwrap();
        let f = crate::paths::KnownFolders::under(dir.path());
        let write = |p: PathBuf| { std::fs::create_dir_all(p.parent().unwrap()).unwrap(); std::fs::write(&p, vec![0u8; 2_000_000]).unwrap(); let old = std::time::SystemTime::now() - std::time::Duration::from_secs(90 * 86_400); std::fs::File::options().write(true).open(&p).unwrap().set_modified(old).unwrap(); };
        write(f.roaming_app_data.join("Zoom/data.bin"));
        write(f.roaming_app_data.join("OldGame/save.bin"));
        write(f.local_app_data.join("FreshTool/x.bin"));
        // FreshTool's folder itself is new (just created), so it's skipped as recently changed.
        for d in ["Zoom", "OldGame"] {
            let p = f.roaming_app_data.join(d);
            let old = std::time::SystemTime::now() - std::time::Duration::from_secs(90 * 86_400);
            std::fs::File::open(&p).map(|h| h.set_modified(old)).ok();
        }
        let policy = SafetyPolicy::new(f);
        let apps = vec![app("Zoom Workplace", "Zoom Video Communications")];
        let (found, _) = leftovers(&policy, &apps, true, &[], &[]);
        let names: Vec<_> = found.iter().map(|x| x.candidate.name.as_str()).collect();
        assert!(!names.contains(&"Zoom"));
        assert!(!names.contains(&"FreshTool"));
        assert!(found.iter().all(|x| !x.candidate.selected && x.candidate.risk == Risk::Review));
        let (none, issues) = leftovers(&policy, &apps, false, &[], &[]);
        assert!(none.is_empty() && !issues.is_empty());
    }
}
