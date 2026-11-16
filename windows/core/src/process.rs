//! What's running, read right before a move. Process names and working folders only: command
//! lines are never read, so nothing secret can end up in a reason or a log.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveProcess {
    pub pid: u32,
    /// Lowercase executable name, e.g. "chrome.exe" (or "node" off Windows).
    pub name: String,
    pub working_directory: Option<PathBuf>,
    /// Where the program file lives (used to tell whether an app is running from a folder).
    pub exe: Option<PathBuf>,
}

pub trait ProcessSource: Send + Sync {
    /// Err when the list couldn't be read; callers treat that as "can't confirm it's idle".
    fn processes(&self) -> Result<Vec<ActiveProcess>, String>;
}

/// The current user's processes via sysinfo.
pub struct SystemProcesses;

impl ProcessSource for SystemProcesses {
    fn processes(&self) -> Result<Vec<ActiveProcess>, String> {
        use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
        let mut sys = System::new().map_err(|e| e.to_string())?;
        sys.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing().with_cwd(UpdateKind::Always).with_exe(UpdateKind::Always),
        );
        Ok(sys.processes()
            .iter()
            .map(|(pid, p)| ActiveProcess {
                pid: pid.as_u32(),
                name: p.name().to_string_lossy().to_lowercase(),
                working_directory: p.cwd().map(Path::to_path_buf),
                exe: p.exe().map(Path::to_path_buf),
            })
            .collect::<Vec<_>>())
    }
}

/// A fixed list, for tests.
pub struct FixedProcesses(pub Vec<ActiveProcess>);

impl ProcessSource for FixedProcesses {
    fn processes(&self) -> Result<Vec<ActiveProcess>, String> {
        Ok(self.0.clone())
    }
}

/// Build tools, package managers and runtimes that write build output and installed packages.
/// Script tools are matched by their interpreter (pip runs as python.exe).
pub const BUILD_TOOLS: &[&str] = &[
    "node.exe", "node", "npm.exe", "npm", "pnpm.exe", "yarn.exe", "bun.exe", "deno.exe",
    "python.exe", "python", "python3", "pythonw.exe", "pip.exe", "uv.exe", "uv",
    "cargo.exe", "cargo", "rustc.exe", "rustc", "java.exe", "java", "gradle.exe", "dotnet.exe", "dotnet",
    "msbuild.exe", "cl.exe", "link.exe", "make.exe", "make", "cmake.exe", "cmake", "ninja.exe", "ninja", "go.exe", "go",
];

fn is_inside(process: &ActiveProcess, folder: &Path) -> bool {
    process.working_directory.as_deref().map(|cwd| crate::fs::is_inside_or_equal(cwd, folder)).unwrap_or(false)
}

/// Why moving `path` now could break something running, or None.
pub fn conflict(path: &Path, owners: &[String], project_folder: Option<&Path>, processes: &[ActiveProcess]) -> Option<String> {
    if let Some(owner) = processes.iter().find(|p| owners.iter().any(|o| o.eq_ignore_ascii_case(&p.name))) {
        return Some(format!("{} is open and uses this. Close it and try again.", owner.name));
    }
    if let Some(running) = processes.iter().find(|p| p.exe.as_deref().map(|e| crate::fs::is_inside_or_equal(e, path)).unwrap_or(false)) {
        return Some(format!("{} is running from this folder. Close it and try again.", running.name));
    }
    if let Some(inside) = processes.iter().find(|p| is_inside(p, path)) {
        return Some(format!("{} is working inside this folder right now. Try again when it's finished.", inside.name));
    }
    if let Some(project) = project_folder {
        if let Some(tool) = processes.iter().find(|p| BUILD_TOOLS.contains(&p.name.as_str()) && is_inside(p, project)) {
            return Some(format!("{} is running in this project and may be using it. Try again when it's finished.", tool.name));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proc(name: &str, cwd: &str) -> ActiveProcess {
        ActiveProcess { pid: 1, name: name.into(), working_directory: Some(PathBuf::from(cwd)), exe: None }
    }

    #[test]
    fn owners_inside_and_project_tools_block() {
        let p = Path::new("/u/code/bot/node_modules");
        assert!(conflict(p, &["chrome.exe".into()], None, &[proc("chrome.exe", "/")]).is_some());
        assert!(conflict(p, &[], None, &[proc("cmd.exe", "/u/code/bot/node_modules/x")]).is_some());
        assert!(conflict(p, &[], Some(Path::new("/u/code/bot")), &[proc("node.exe", "/u/code/bot")]).is_some());
        assert!(conflict(p, &[], Some(Path::new("/u/code/bot")), &[proc("explorer.exe", "/u/code/bot")]).is_none());
        assert!(conflict(p, &[], None, &[proc("node.exe", "/u/code/bot-old")]).is_none());
    }
}
