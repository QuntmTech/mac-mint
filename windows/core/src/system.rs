//! Readings about the PC: drives, memory, processor and running apps, the Recycle Bin, and
//! lowering an app's priority (the Windows counterpart of the Mac app's "slow down").
use serde::{Deserialize, Serialize};
use sysinfo::{Disks, ProcessRefreshKind, ProcessesToUpdate, System};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskInfo {
    pub name: String,
    pub mount: String,
    pub total: u64,
    pub free: u64,
    pub is_system: bool,
}

pub fn disks() -> Vec<DiskInfo> {
    let system_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into()).to_lowercase();
    let Ok(disks) = Disks::new_with_refreshed_list() else { return vec![] };
    let mut out: Vec<DiskInfo> = (&disks)
        .into_iter()
        .filter(|d| d.total_space() > 0)
        .map(|d| {
            let mount = d.mount_point().display().to_string();
            let is_system = mount.to_lowercase().starts_with(&system_drive) || mount == "/";
            let label = d.name().to_string_lossy().to_string();
            DiskInfo {
                name: if label.is_empty() { format!("Local Disk ({})", mount.trim_end_matches('\\')) } else { format!("{label} ({})", mount.trim_end_matches('\\')) },
                mount,
                total: d.total_space(),
                free: d.available_space(),
                is_system,
            }
        })
        .collect();
    out.sort_by_key(|d| (!d.is_system, d.mount.clone()));
    out.dedup_by(|a, b| a.mount == b.mount);
    out
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessInfo {
    pub pid: u32,
    pub name: String,
    pub cpu_percent: f32,
    pub memory: u64,
    pub lowered: bool,
    pub can_lower: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Memory {
    pub total: u64,
    pub used: u64,
}

/// Programs that keep Windows running. Never offered for lowering.
const SYSTEM_PROCESSES: &[&str] = &[
    "system", "registry", "smss.exe", "csrss.exe", "wininit.exe", "winlogon.exe", "services.exe", "lsass.exe", "svchost.exe",
    "dwm.exe", "explorer.exe", "fontdrvhost.exe", "memory compression", "sihost.exe", "ctfmon.exe", "audiodg.exe",
    "msmpeng.exe", "searchindexer.exe", "taskmgr.exe", "macmint.exe", "runtimebroker.exe", "startmenuexperiencehost.exe",
];

/// Live readings kept between calls; processor use needs two samples.
pub struct Monitor {
    sys: Option<System>,
}

impl Default for Monitor {
    fn default() -> Self {
        Self::new()
    }
}

impl Monitor {
    pub fn new() -> Self {
        let sys = System::new().ok().map(|mut sys| {
            sys.refresh_cpu_usage();
            sys.refresh_memory();
            sys
        });
        Self { sys }
    }

    pub fn cpu_percent(&mut self) -> f32 {
        let Some(sys) = self.sys.as_mut() else { return 0.0 };
        sys.refresh_cpu_usage();
        sys.global_cpu_usage()
    }

    pub fn memory(&mut self) -> Memory {
        let Some(sys) = self.sys.as_mut() else { return Memory { total: 0, used: 0 } };
        sys.refresh_memory();
        Memory { total: sys.total_memory(), used: sys.used_memory() }
    }

    pub fn uptime() -> u64 {
        System::uptime().unwrap_or(0)
    }

    /// Apps grouped by program name (Chrome's many helpers count as one), heaviest first.
    pub fn processes(&mut self, lowered: &std::collections::HashSet<u32>) -> Vec<ProcessInfo> {
        let Some(sys) = self.sys.as_mut() else { return vec![] };
        sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_cpu().with_memory());
        let cores = sys.cpus().len().max(1) as f32;
        let mut by_name: std::collections::HashMap<String, ProcessInfo> = std::collections::HashMap::new();
        for (pid, p) in sys.processes() {
            let name = p.name().to_string_lossy().to_string();
            let key = name.to_lowercase();
            let e = by_name.entry(key.clone()).or_insert(ProcessInfo {
                pid: pid.as_u32(),
                name: name.trim_end_matches(".exe").to_string(),
                cpu_percent: 0.0,
                memory: 0,
                lowered: false,
                can_lower: !SYSTEM_PROCESSES.contains(&key.as_str()),
            });
            e.cpu_percent += p.cpu_usage() / cores;
            e.memory += p.memory();
            if lowered.contains(&pid.as_u32()) {
                e.lowered = true;
                e.pid = pid.as_u32();
            }
        }
        let mut list: Vec<_> = by_name.into_values().collect();
        list.sort_by(|a, b| (b.memory as f64 + b.cpu_percent as f64 * 50e6).total_cmp(&(a.memory as f64 + a.cpu_percent as f64 * 50e6)));
        list.truncate(40);
        list
    }

    /// Every process ID running the same program as `pid`.
    pub fn family(&self, pid: u32) -> Vec<u32> {
        let Some(sys) = self.sys.as_ref() else { return vec![pid] };
        let Some(name) = sys.process(sysinfo::Pid::from_u32(pid)).map(|p| p.name().to_os_string()) else { return vec![pid] };
        sys.processes().iter().filter(|(_, p)| p.name() == name).map(|(id, _)| id.as_u32()).collect()
    }

    pub fn name_of(&self, pid: u32) -> Option<String> {
        self.sys.as_ref()?.process(sysinfo::Pid::from_u32(pid)).map(|p| p.name().to_string_lossy().to_lowercase())
    }
}

/// Lowers (or restores) a program's priority so it yields to what you're doing. Lasts until the
/// program restarts; nothing is closed and nothing is saved anywhere.
#[cfg(windows)]
pub fn set_priority(pid: u32, low: bool) -> Result<(), String> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess, SetPriorityClass, BELOW_NORMAL_PRIORITY_CLASS, NORMAL_PRIORITY_CLASS, PROCESS_SET_INFORMATION};
    unsafe {
        let h = OpenProcess(PROCESS_SET_INFORMATION, 0, pid);
        if h.is_null() {
            return Err("Windows didn't allow changing this app (it may belong to another user or be protected).".into());
        }
        let ok = SetPriorityClass(h, if low { BELOW_NORMAL_PRIORITY_CLASS } else { NORMAL_PRIORITY_CLASS });
        CloseHandle(h);
        if ok == 0 { Err("Windows didn't accept the change.".into()) } else { Ok(()) }
    }
}

#[cfg(not(windows))]
pub fn set_priority(_pid: u32, _low: bool) -> Result<(), String> {
    Err("Changing priority is only available on Windows.".into())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RecycleBinInfo {
    pub bytes: u64,
    pub items: u64,
}

#[cfg(windows)]
pub fn recycle_bin() -> RecycleBinInfo {
    use windows_sys::Win32::UI::Shell::{SHQueryRecycleBinW, SHQUERYRBINFO};
    let mut info = SHQUERYRBINFO { cbSize: std::mem::size_of::<SHQUERYRBINFO>() as u32, i64Size: 0, i64NumItems: 0 };
    let hr = unsafe { SHQueryRecycleBinW(std::ptr::null(), &mut info) };
    if hr < 0 { RecycleBinInfo::default() } else { RecycleBinInfo { bytes: info.i64Size.max(0) as u64, items: info.i64NumItems.max(0) as u64 } }
}

#[cfg(not(windows))]
pub fn recycle_bin() -> RecycleBinInfo {
    RecycleBinInfo::default()
}

/// Empties the Recycle Bin for good. The window asks the person first.
#[cfg(windows)]
pub fn empty_recycle_bin() -> Result<(), String> {
    use windows_sys::Win32::UI::Shell::{SHEmptyRecycleBinW, SHERB_NOCONFIRMATION, SHERB_NOPROGRESSUI, SHERB_NOSOUND};
    let hr = unsafe { SHEmptyRecycleBinW(std::ptr::null_mut(), std::ptr::null(), SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND) };
    // An already-empty bin reports an error code; that's fine.
    if hr < 0 && recycle_bin().items > 0 { Err(format!("Windows couldn't empty the Recycle Bin (0x{:08x}).", hr as u32)) } else { Ok(()) }
}

#[cfg(not(windows))]
pub fn empty_recycle_bin() -> Result<(), String> {
    Err("Only available on Windows.".into())
}

pub fn computer_name() -> String {
    System::host_name().ok().unwrap_or_else(|| "This PC".into())
}

pub fn os_version() -> String {
    System::long_os_version().ok().unwrap_or_else(|| "Windows".into())
}
