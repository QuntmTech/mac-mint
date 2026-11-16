//! Apps that start with Windows: the Run keys and the Startup folders, with the same on/off
//! switch Task Manager uses (StartupApproved). Only the current user's items can be switched
//! here; all-users items need an administrator, so the app points to Task Manager for those.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartupItem {
    pub id: String,
    pub name: String,
    pub command: String,
    pub location: String,
    pub enabled: bool,
    pub can_toggle: bool,
    pub publisher: Option<String>,
}

/// Task Manager's StartupApproved value: an even first byte means on, odd means off.
pub fn approved_enabled(value: Option<&[u8]>) -> bool {
    match value {
        Some(v) if !v.is_empty() => v[0] % 2 == 0,
        _ => true,
    }
}

/// The 12-byte value Task Manager writes: state, then the time it was switched off.
pub fn approved_value(enabled: bool, filetime: u64) -> Vec<u8> {
    let mut v = vec![if enabled { 2 } else { 3 }, 0, 0, 0];
    v.extend_from_slice(&if enabled { 0u64 } else { filetime }.to_le_bytes());
    v
}

#[cfg(windows)]
mod platform {
    use super::*;
    use winreg::enums::*;
    use winreg::{RegKey, RegValue};

    const RUN: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    const RUN32: &str = "Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run";
    const APPROVED: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved";

    fn approved(hive: winreg::HKEY, sub: &str, name: &str) -> bool {
        let v = RegKey::predef(hive).open_subkey(format!("{APPROVED}\\{sub}")).and_then(|k| k.get_raw_value(name)).ok();
        approved_enabled(v.as_ref().map(|r| &r.bytes[..]))
    }

    fn startup_folder_items(dir: &std::path::Path, location: &str, can_toggle: bool, hive: winreg::HKEY, out: &mut Vec<StartupItem>) {
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.eq_ignore_ascii_case("desktop.ini") {
                continue;
            }
            out.push(StartupItem {
                id: format!("{location}:{name}"),
                name: name.trim_end_matches(".lnk").to_string(),
                command: e.path().display().to_string(),
                location: location.into(),
                enabled: approved(hive, "StartupFolder", &name),
                can_toggle,
                publisher: None,
            });
        }
    }

    pub fn list() -> Vec<StartupItem> {
        let mut out = Vec::new();
        for (hive, path, location, approved_sub, can_toggle) in [
            (HKEY_CURRENT_USER, RUN, "currentUserRun", "Run", true),
            (HKEY_LOCAL_MACHINE, RUN, "allUsersRun", "Run", false),
            (HKEY_LOCAL_MACHINE, RUN32, "allUsersRun", "Run32", false),
        ] {
            let Ok(key) = RegKey::predef(hive).open_subkey(path) else { continue };
            for (name, value) in key.enum_values().flatten() {
                let command = value.to_string();
                out.push(StartupItem {
                    id: format!("{location}:{approved_sub}:{name}"),
                    enabled: approved(hive, approved_sub, &name),
                    name,
                    command: command.trim_matches('"').to_string(),
                    location: location.into(),
                    can_toggle,
                    publisher: None,
                });
            }
        }
        if let Some(appdata) = std::env::var_os("APPDATA") {
            startup_folder_items(&std::path::Path::new(&appdata).join("Microsoft\\Windows\\Start Menu\\Programs\\Startup"), "startupFolder", true, HKEY_CURRENT_USER, &mut out);
        }
        if let Some(pd) = std::env::var_os("ProgramData") {
            startup_folder_items(&std::path::Path::new(&pd).join("Microsoft\\Windows\\Start Menu\\Programs\\Startup"), "allUsersStartupFolder", false, HKEY_LOCAL_MACHINE, &mut out);
        }
        out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        out
    }

    pub fn set_enabled(id: &str, enabled: bool) -> Result<StartupItem, String> {
        let item = list().into_iter().find(|i| i.id == id).ok_or("That startup item is gone. Refresh the list.")?;
        if !item.can_toggle {
            return Err("This item starts for every user. Turn it off in Task Manager (it needs an administrator).".into());
        }
        let (sub, value_name) = if item.location == "startupFolder" {
            ("StartupFolder".to_string(), id.trim_start_matches("startupFolder:").to_string())
        } else {
            let mut parts = id.splitn(3, ':');
            let _ = parts.next();
            (parts.next().unwrap_or("Run").to_string(), parts.next().unwrap_or_default().to_string())
        };
        let (key, _) = RegKey::predef(HKEY_CURRENT_USER).create_subkey(format!("{APPROVED}\\{sub}")).map_err(|e| e.to_string())?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let filetime = (now + 11_644_473_600) * 10_000_000;
        key.set_raw_value(&value_name, &RegValue { bytes: approved_value(enabled, filetime).into(), vtype: REG_BINARY }).map_err(|e| e.to_string())?;
        Ok(StartupItem { enabled, ..item })
    }
}

#[cfg(windows)]
pub use platform::{list, set_enabled};

#[cfg(not(windows))]
pub fn list() -> Vec<StartupItem> {
    vec![]
}

#[cfg(not(windows))]
pub fn set_enabled(_id: &str, _enabled: bool) -> Result<StartupItem, String> {
    Err("Startup items can only be changed on Windows.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_writes_task_manager_values() {
        assert!(approved_enabled(None));
        assert!(approved_enabled(Some(&[2, 0, 0, 0])));
        assert!(approved_enabled(Some(&[6, 0])));
        assert!(!approved_enabled(Some(&[3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])));
        let off = approved_value(false, 42);
        assert_eq!(off.len(), 12);
        assert!(!approved_enabled(Some(&off)));
        assert!(approved_enabled(Some(&approved_value(true, 42))));
    }
}
