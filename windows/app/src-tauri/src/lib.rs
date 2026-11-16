//! The bridge between the window and the engine. Every command here only looks, except
//! run_plan (moves reviewed items to the Recycle Bin), restore, empty_recycle_bin (after the
//! window's own confirmation), set_startup_enabled, set_low_priority and uninstall_app (which
//! starts the app's own uninstaller). Moving files needs an unlocked account, as on the Mac.
mod account;
mod settings;
mod updates;

use macmint_core::apps::{self, InstalledApp};
use macmint_core::developer::{self, DeveloperItem};
use macmint_core::executor::{recover_journal, Executor, OperationReport, Progress};
use macmint_core::history::HistoryStore;
use macmint_core::model::{Candidate, Found, ScanIssue};
use macmint_core::paths::KnownFolders;
use macmint_core::plan::{self, OperationPlan, PlanItem};
use macmint_core::process::{ProcessSource, SystemProcesses};
use macmint_core::recommend::{self, Inputs, ScanArea, SmartScan};
use macmint_core::safety::SafetyPolicy;
use macmint_core::system::{self, Monitor};
use macmint_core::trash::{RecycleBin, TrashService};
use serde_json::{json, Value};
use settings::Settings;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

const VERSION: &str = env!("CARGO_PKG_VERSION");

pub struct Inner {
    policy: SafetyPolicy,
    data: PathBuf,
    candidates: Mutex<HashMap<String, PlanItem>>,
    plans: Mutex<HashMap<String, OperationPlan>>,
    apps: Mutex<Vec<InstalledApp>>,
    monitor: Mutex<Monitor>,
    lowered: Mutex<HashSet<u32>>,
    cancel_scan: AtomicBool,
    cancel_op: AtomicBool,
    operation_running: AtomicBool,
    smart: Mutex<Option<SmartScan>>,
    settings: Mutex<Settings>,
    account: tauri::async_runtime::Mutex<account::Account>,
    ai_history: Mutex<Vec<(String, String)>>,
    pending_update: Mutex<Option<updates::UpdateInfo>>,
}

type St<'a> = State<'a, Arc<Inner>>;
type R<T> = Result<T, String>;

impl Inner {
    fn excluded(&self) -> Vec<PathBuf> {
        self.settings.lock().unwrap().excluded_paths()
    }
    fn remember(&self, found: &[Found]) {
        let mut map = self.candidates.lock().unwrap();
        for f in found {
            map.insert(f.candidate.id.clone(), f.item.clone());
        }
    }
    fn processes(&self) -> Vec<macmint_core::process::ActiveProcess> {
        SystemProcesses.processes().unwrap_or_default()
    }
    fn history(&self) -> HistoryStore {
        HistoryStore { path: self.data.join("history.json") }
    }
    fn device(&self) -> account::Device {
        account::device(&format!("{VERSION} (build {}) Windows", updates::current_build()))
    }
}

/// Runs blocking work off the window's thread.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> R<T> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| format!("MacMint hit an internal error: {e}"))
}

fn candidates(found: &[Found]) -> Vec<Candidate> {
    found.iter().map(|f| f.candidate.clone()).collect()
}

fn issues_json(issues: &[ScanIssue]) -> Value {
    serde_json::to_value(issues).unwrap_or(Value::Array(vec![]))
}

fn dev_json(item: &DeveloperItem) -> Value {
    let mut v = serde_json::to_value(item.to_found().candidate).unwrap_or(Value::Null);
    if let Some(o) = v.as_object_mut() {
        o.insert("project".into(), json!(item.project));
        o.insert("projectName".into(), json!(item.project_name));
        o.insert("tool".into(), json!(item.tool));
        o.insert("kind".into(), serde_json::to_value(item.kind).unwrap_or(Value::Null));
        o.insert("lastActivity".into(), json!(item.last_activity));
    }
    v
}

// ---------- Overview and Smart Scan ----------

#[tauri::command]
fn app_info(state: St) -> Value {
    json!({ "version": VERSION, "build": updates::current_build(), "platform": system::os_version(), "dataFolder": state.data })
}

#[tauri::command]
async fn get_overview(state: St<'_>) -> R<Value> {
    let inner = state.inner().clone();
    blocking(move || {
        let (cpu, memory) = {
            let mut m = inner.monitor.lock().unwrap();
            (m.cpu_percent(), m.memory())
        };
        json!({
            "computerName": system::computer_name(),
            "osVersion": system::os_version(),
            "disks": system::disks(),
            "memory": memory,
            "cpuPercent": cpu,
            "uptimeSeconds": Monitor::uptime(),
            "recycleBin": system::recycle_bin(),
            "lastSmartScan": *inner.smart.lock().unwrap(),
        })
    })
    .await
}

fn progress(app: &AppHandle, area: &str, message: &str, fraction: f32) {
    let _ = app.emit("scan-progress", json!({ "area": area, "message": message, "fraction": fraction }));
}

#[tauri::command]
fn cancel_scan(state: St) {
    state.cancel_scan.store(true, Ordering::SeqCst);
}

#[tauri::command]
async fn run_smart_scan(app: AppHandle, state: St<'_>) -> R<SmartScan> {
    let inner = state.inner().clone();
    inner.cancel_scan.store(false, Ordering::SeqCst);
    blocking(move || {
        let cancel = &inner.cancel_scan;
        let excluded = inner.excluded();
        let procs = inner.processes();
        progress(&app, "Junk and caches", "Looking at temporary files and app caches…", 0.05);
        let cleanup = macmint_core::cleanup::scan(&inner.policy, &procs, &excluded, cancel);
        inner.remember(&cleanup.found);
        progress(&app, "Developer", "Looking for old build folders in your projects…", 0.35);
        let home = inner.policy.folders().home.clone();
        let dev = developer::scan_projects(&[home], 6, &excluded, cancel);
        let dev_found: Vec<Found> = dev.value.iter().map(|d| d.to_found()).collect();
        inner.remember(&dev_found);
        progress(&app, "Apps", "Checking installed apps and leftover data…", 0.65);
        let (installed, complete) = apps::installed_apps(&procs);
        let (leftovers, left_issues) = apps::leftovers(&inner.policy, &installed, complete, &procs, &excluded);
        inner.remember(&leftovers);
        *inner.apps.lock().unwrap() = installed;
        progress(&app, "Startup", "Checking what starts with Windows…", 0.85);
        let startup = macmint_core::startup::list();
        let disks = system::disks();
        let sys_disk = disks.iter().find(|d| d.is_system).map(|d| (d.total, d.free));
        let bin = system::recycle_bin();
        let cancelled = cancel.load(Ordering::SeqCst);
        let bytes = |f: &[Found]| f.iter().filter(|x| x.candidate.selected).map(|x| x.candidate.bytes).sum::<u64>();
        let areas = vec![
            ScanArea::from("cleanup", "Junk and caches", bytes(&cleanup.found), &cleanup.issues, cleanup.cancelled),
            ScanArea::from("developer", "Developer", dev.value.iter().filter(|d| d.suggested).map(|d| d.bytes).sum(), &dev.issues, dev.cancelled),
            ScanArea::from("apps", "Apps and leftovers", 0, &left_issues, cancelled),
            ScanArea::from("startup", "Startup", 0, &[], cancelled),
            ScanArea::from("storage", "Storage", 0, &if sys_disk.is_none() { vec![ScanIssue::new("Storage", None, "Couldn't read the system drive.")] } else { vec![] }, false),
        ];
        let recs = recommend::recommendations(&Inputs {
            cleanup: &cleanup.found,
            developer: &dev.value,
            leftovers: &leftovers,
            startup_enabled: startup.iter().filter(|s| s.enabled).count(),
            system_disk: sys_disk,
            recycle_bin_bytes: bin.bytes,
        });
        let scan = SmartScan { checked_at: macmint_core::fs::now_secs(), reclaimable_bytes: recommend::reclaimable(&recs), areas, recommendations: recs };
        let _ = macmint_core::executor::write_durably(&inner.data.join("smart-scan.json"), &serde_json::to_vec(&scan).unwrap_or_default());
        *inner.smart.lock().unwrap() = Some(scan.clone());
        progress(&app, "Done", "Scan finished.", 1.0);
        scan
    })
    .await
}

#[tauri::command]
async fn scan_cleanup(state: St<'_>) -> R<Value> {
    let inner = state.inner().clone();
    inner.cancel_scan.store(false, Ordering::SeqCst);
    blocking(move || {
        let procs = inner.processes();
        let r = macmint_core::cleanup::scan(&inner.policy, &procs, &inner.excluded(), &inner.cancel_scan);
        inner.remember(&r.found);
        let summaries = [
            (macmint_core::model::CleanupCategory::TempFiles, "Files apps and installers left in Temp. Anything still in use is skipped."),
            (macmint_core::model::CleanupCategory::AppCaches, "Copies apps keep to load faster. They rebuild as you use the app."),
            (macmint_core::model::CleanupCategory::LogsAndReports, "Crash dumps and error reports. Only useful when troubleshooting."),
            (macmint_core::model::CleanupCategory::DeveloperCaches, "Downloads your developer tools fetch again when needed."),
            (macmint_core::model::CleanupCategory::Installers, "Installers and archives in Downloads older than a month."),
        ];
        let groups: Vec<Value> = summaries
            .iter()
            .map(|(cat, summary)| {
                let mut items: Vec<Candidate> = r.found.iter().filter(|f| f.candidate.category == cat.key()).map(|f| f.candidate.clone()).collect();
                items.sort_by(|a, b| b.bytes.cmp(&a.bytes));
                json!({ "category": cat.key(), "title": cat.title(), "summary": summary, "items": items })
            })
            .collect();
        json!({ "checkedAt": macmint_core::fs::now_secs(), "groups": groups, "issues": issues_json(&r.issues), "recycleBin": system::recycle_bin() })
    })
    .await
}

#[tauri::command]
async fn scan_developer(state: St<'_>) -> R<Value> {
    let inner = state.inner().clone();
    inner.cancel_scan.store(false, Ordering::SeqCst);
    blocking(move || {
        let excluded = inner.excluded();
        let home = inner.policy.folders().home.clone();
        let dev = developer::scan_projects(&[home], 6, &excluded, &inner.cancel_scan);
        let found: Vec<Found> = dev.value.iter().map(|d| d.to_found()).collect();
        inner.remember(&found);
        let procs = inner.processes();
        let cleanup = macmint_core::cleanup::scan(&inner.policy, &procs, &excluded, &inner.cancel_scan);
        let caches: Vec<Found> = cleanup.found.into_iter().filter(|f| f.candidate.category == "developerCaches").collect();
        inner.remember(&caches);
        json!({ "checkedAt": macmint_core::fs::now_secs(), "items": dev.value.iter().map(dev_json).collect::<Vec<_>>(), "caches": candidates(&caches), "issues": issues_json(&dev.issues) })
    })
    .await
}

// ---------- Apps and startup ----------

#[tauri::command]
async fn list_apps(state: St<'_>) -> R<Vec<InstalledApp>> {
    let inner = state.inner().clone();
    blocking(move || {
        let (list, _) = apps::installed_apps(&inner.processes());
        *inner.apps.lock().unwrap() = list.clone();
        list
    })
    .await
}

#[tauri::command]
async fn uninstall_app(state: St<'_>, id: String) -> R<String> {
    let app = state.apps.lock().unwrap().iter().find(|a| a.id == id).cloned().ok_or("That app isn't in the list anymore. Refresh it.")?;
    if !state.account.lock().await.unlocked() {
        return Err("Sign in with an active MacMint plan to uninstall apps.".into());
    }
    apps::uninstall(&app)
}

#[tauri::command]
async fn find_leftovers(state: St<'_>, id: String) -> R<Vec<Candidate>> {
    let inner = state.inner().clone();
    blocking(move || {
        let app = inner.apps.lock().unwrap().iter().find(|a| a.id == id).cloned();
        let found = match app {
            Some(a) => apps::leftovers_for(&inner.policy, &a, &inner.excluded()),
            None => {
                let procs = inner.processes();
                let (installed, complete) = apps::installed_apps(&procs);
                apps::leftovers(&inner.policy, &installed, complete, &procs, &inner.excluded()).0
            }
        };
        inner.remember(&found);
        candidates(&found)
    })
    .await
}

#[tauri::command]
async fn list_startup() -> R<Vec<macmint_core::startup::StartupItem>> {
    blocking(macmint_core::startup::list).await
}

#[tauri::command]
fn set_startup_enabled(id: String, enabled: bool) -> R<macmint_core::startup::StartupItem> {
    macmint_core::startup::set_enabled(&id, enabled)
}

#[tauri::command]
fn open_task_manager_startup() -> R<()> {
    std::process::Command::new("taskmgr.exe").args(["/0", "/startup"]).spawn().map(|_| ()).map_err(|e| format!("Couldn't open Task Manager: {e}"))
}

// ---------- Storage and files ----------

#[tauri::command]
async fn storage_breakdown(state: St<'_>, path: Option<String>) -> R<macmint_core::storage::StorageBreakdown> {
    let inner = state.inner().clone();
    blocking(move || {
        let p = path.map(PathBuf::from).unwrap_or_else(|| inner.policy.folders().home.clone());
        macmint_core::storage::breakdown(&p, &inner.excluded())
    })
    .await?
}

#[tauri::command]
async fn large_files(state: St<'_>, min_bytes: u64) -> R<Value> {
    let inner = state.inner().clone();
    inner.cancel_scan.store(false, Ordering::SeqCst);
    blocking(move || {
        let r = macmint_core::storage::large_files(&inner.policy, min_bytes.max(10_000_000), &inner.excluded(), &inner.cancel_scan);
        inner.remember(&r.value);
        json!({ "value": candidates(&r.value), "issues": issues_json(&r.issues), "cancelled": r.cancelled })
    })
    .await
}

#[tauri::command]
async fn old_downloads(state: St<'_>) -> R<Value> {
    let inner = state.inner().clone();
    inner.cancel_scan.store(false, Ordering::SeqCst);
    blocking(move || {
        let r = macmint_core::storage::old_downloads(&inner.policy, &inner.excluded(), &inner.cancel_scan);
        inner.remember(&r.value);
        json!({ "value": candidates(&r.value), "issues": issues_json(&r.issues), "cancelled": r.cancelled })
    })
    .await
}

#[tauri::command]
async fn find_duplicates(state: St<'_>) -> R<Value> {
    let inner = state.inner().clone();
    inner.cancel_scan.store(false, Ordering::SeqCst);
    blocking(move || {
        let r = macmint_core::storage::duplicates(&inner.policy, &inner.excluded(), &inner.cancel_scan);
        let groups: Vec<Value> = r
            .value
            .iter()
            .map(|g| {
                inner.remember(&g.files);
                json!({ "id": g.id, "bytes": g.bytes, "files": candidates(&g.files) })
            })
            .collect();
        json!({ "value": groups, "issues": issues_json(&r.issues), "cancelled": r.cancelled })
    })
    .await
}

// ---------- Performance ----------

#[tauri::command]
async fn performance(state: St<'_>) -> R<Value> {
    let inner = state.inner().clone();
    blocking(move || {
        let lowered = inner.lowered.lock().unwrap().clone();
        let mut m = inner.monitor.lock().unwrap();
        let processes = m.processes(&lowered);
        json!({
            "cpuPercent": m.cpu_percent(),
            "memory": m.memory(),
            "processes": processes,
            "startupEnabled": macmint_core::startup::list().iter().filter(|s| s.enabled).count(),
            "uptimeSeconds": Monitor::uptime(),
        })
    })
    .await
}

#[tauri::command]
fn set_low_priority(state: St, pid: u32, low: bool) -> R<Value> {
    let family = state.monitor.lock().unwrap().family(pid);
    let name = state.monitor.lock().unwrap().name_of(pid).unwrap_or_default();
    let mut changed = 0;
    let mut last_err = None;
    for p in &family {
        match system::set_priority(*p, low) {
            Ok(()) => {
                changed += 1;
                let mut l = state.lowered.lock().unwrap();
                if low { l.insert(*p); } else { l.remove(p); }
            }
            Err(e) => last_err = Some(e),
        }
    }
    if changed == 0 {
        return Err(last_err.unwrap_or_else(|| "That app isn't running anymore.".into()));
    }
    Ok(json!({ "pid": pid, "name": name.trim_end_matches(".exe"), "cpuPercent": 0.0, "memory": 0, "lowered": low, "canLower": true }))
}

// ---------- Plans, moving and History ----------

#[tauri::command]
async fn prepare_plan(state: St<'_>, title: String, ids: Vec<String>) -> R<Value> {
    let inner = state.inner().clone();
    blocking(move || {
        let items: Vec<PlanItem> = {
            let map = inner.candidates.lock().unwrap();
            ids.iter().filter_map(|id| map.get(id).cloned()).collect()
        };
        if items.is_empty() {
            return Err("Nothing to review. Scan again first.".to_string());
        }
        let p = plan::plan(&title, items, &inner.excluded());
        let plan_id = format!("plan-{}-{}", macmint_core::fs::now_secs(), p.items.len());
        let total = p.total_bytes();
        let mut v = serde_json::to_value(&p).map_err(|e| e.to_string())?;
        v["planId"] = json!(plan_id);
        v["totalBytes"] = json!(total);
        inner.plans.lock().unwrap().insert(plan_id, p);
        Ok(v)
    })
    .await?
}

#[tauri::command]
fn cancel_operation(state: St) {
    state.cancel_op.store(true, Ordering::SeqCst);
}

fn report_json(r: &OperationReport) -> Value {
    let mut v = serde_json::to_value(r).unwrap_or(Value::Null);
    v["summary"] = json!(r.summary());
    v["bytesMoved"] = json!(r.bytes_moved());
    v
}

#[tauri::command]
async fn run_plan(app: AppHandle, state: St<'_>, plan_id: String) -> R<Value> {
    let inner = state.inner().clone();
    {
        let mut account = inner.account.lock().await;
        if !account.unlocked() {
            account.refresh(&inner.data, &inner.device()).await;
            if !account.unlocked() {
                return Err("Sign in with an active MacMint plan to move files. Scanning stays free.".into());
            }
        }
    }
    let plan = inner.plans.lock().unwrap().remove(&plan_id).ok_or("This review expired. Review the items again.")?;
    if inner.operation_running.swap(true, Ordering::SeqCst) {
        inner.plans.lock().unwrap().insert(plan_id, plan);
        return Err("Another cleanup is still running.".into());
    }
    inner.cancel_op.store(false, Ordering::SeqCst);
    let result = blocking(move || {
        let journal = inner.data.join("journal.json");
        let excluded = inner.excluded();
        let exec = Executor { policy: &inner.policy, trash: &RecycleBin, processes: &SystemProcesses, journal: Some(journal.clone()), excluded };
        let report = exec.run(&plan, &inner.cancel_op, |p: Progress| {
            let _ = app.emit("operation-progress", p);
        });
        let saved = inner.history().record(&report);
        if saved.is_ok() {
            let _ = std::fs::remove_file(&journal);
        }
        inner.operation_running.store(false, Ordering::SeqCst);
        let moved: Vec<String> = report.moved().map(|o| o.item.id.clone()).collect();
        inner.candidates.lock().unwrap().retain(|k, _| !moved.contains(k));
        let mut v = report_json(&report);
        if let Err(e) = saved {
            v["summary"] = json!(format!("{} (History couldn't be saved: {e})", report.summary()));
        }
        v
    })
    .await;
    result
}

#[tauri::command]
async fn history(state: St<'_>) -> R<Value> {
    let inner = state.inner().clone();
    blocking(move || {
        let entries = inner.history().load()?;
        let out: Vec<Value> = entries
            .iter()
            .map(|e| {
                let receipts: Vec<Value> = e
                    .receipts
                    .iter()
                    .map(|r| {
                        let restored = e.restored.iter().any(|p| macmint_core::fs::comparison_key(p) == macmint_core::fs::comparison_key(&r.original_path));
                        json!({ "originalPath": r.original_path, "bytes": r.bytes, "trashedAt": r.trashed_at, "restored": restored })
                    })
                    .collect();
                json!({ "id": e.id, "title": e.title, "date": e.date, "bytes": e.bytes, "notes": e.notes, "receipts": receipts, "uncertain": e.uncertain })
            })
            .collect();
        Ok::<_, String>(Value::Array(out))
    })
    .await?
}

#[tauri::command]
async fn restore(state: St<'_>, entry_id: String, original_path: String) -> R<String> {
    let inner = state.inner().clone();
    blocking(move || {
        let store = inner.history();
        let entries = store.load()?;
        let entry = entries.iter().find(|e| e.id == entry_id).ok_or("That History entry is gone.")?;
        let key = macmint_core::fs::comparison_key(Path::new(&original_path));
        let receipt = entry.receipts.iter().find(|r| macmint_core::fs::comparison_key(&r.original_path) == key).ok_or("That item isn't part of this entry.")?;
        RecycleBin.restore(receipt)?;
        store.mark_restored(&entry_id, &receipt.original_path)?;
        Ok(format!("Put back {}.", receipt.original_path.display()))
    })
    .await?
}

#[tauri::command]
async fn empty_recycle_bin() -> R<String> {
    blocking(|| system::empty_recycle_bin().map(|_| "The Recycle Bin is empty.".to_string())).await?
}

// ---------- Settings, account, AI, updates ----------

#[tauri::command]
fn get_settings(state: St) -> Settings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
fn save_settings(state: St, settings: Settings) -> R<Settings> {
    let s = settings.sanitized();
    s.save(&state.data)?;
    *state.settings.lock().unwrap() = s.clone();
    Ok(s)
}

#[tauri::command]
async fn account_status(state: St<'_>) -> R<account::AccountStatus> {
    let consent = state.settings.lock().unwrap().ai_enabled;
    let device = state.device();
    Ok(state.account.lock().await.status(&device.name, consent))
}

#[tauri::command]
async fn sign_in(state: St<'_>, email: String, password: String) -> R<account::AccountStatus> {
    let device = state.device();
    let consent = state.settings.lock().unwrap().ai_enabled;
    let mut a = state.account.lock().await;
    a.sign_in(&state.data, &device, &email, &password).await?;
    a.refresh_ai_status().await;
    Ok(a.status(&device.name, consent))
}

#[tauri::command]
async fn sign_out(state: St<'_>) -> R<account::AccountStatus> {
    let device = state.device();
    let mut a = state.account.lock().await;
    a.sign_out_locally(&state.data);
    state.ai_history.lock().unwrap().clear();
    Ok(a.status(&device.name, false))
}

#[tauri::command]
async fn refresh_account(state: St<'_>) -> R<account::AccountStatus> {
    let device = state.device();
    let consent = state.settings.lock().unwrap().ai_enabled;
    let mut a = state.account.lock().await;
    a.refresh(&state.data, &device).await;
    a.refresh_ai_status().await;
    Ok(a.status(&device.name, consent))
}

#[tauri::command]
async fn ai_ask(state: St<'_>, question: String) -> R<Value> {
    if !state.settings.lock().unwrap().ai_enabled {
        return Err("Turn on the optional assistant in Settings first.".into());
    }
    let token = {
        let mut a = state.account.lock().await;
        a.refresh_ai_status().await;
        if !a.unlocked() {
            return Err("The assistant needs an active MacMint plan.".into());
        }
        if !a.ai_reachable {
            return Err("MacMint couldn't reach the assistant. Check your connection.".into());
        }
        if !a.ai_enabled_remote {
            return Err("The assistant is turned off by the service right now.".into());
        }
        a.token.clone().ok_or("Sign in to use the assistant.")?
    };
    let (total, free) = system::disks().iter().find(|d| d.is_system).map(|d| (d.total as f64 / 1e9, d.free as f64 / 1e9)).unwrap_or((0.0, 0.0));
    let history = state.ai_history.lock().unwrap().clone();
    let answer = account::ask(&token, &question, &history, (total * 10.0).round() / 10.0, (free * 10.0).round() / 10.0).await?;
    {
        let mut h = state.ai_history.lock().unwrap();
        h.push(("user".into(), question));
        h.push(("assistant".into(), answer.clone()));
        let len = h.len();
        if len > 12 {
            h.drain(..len - 12);
        }
    }
    Ok(json!({ "answer": answer, "remaining": null }))
}

#[tauri::command]
async fn check_updates(state: St<'_>) -> R<updates::UpdateInfo> {
    let info = updates::check(VERSION).await;
    *state.pending_update.lock().unwrap() = Some(info.clone());
    Ok(info)
}

#[tauri::command]
async fn install_update(app: AppHandle, state: St<'_>) -> R<String> {
    if state.operation_running.load(Ordering::SeqCst) {
        return Err("Wait for the cleanup to finish before updating.".into());
    }
    let info = match state.pending_update.lock().unwrap().clone() {
        Some(i) if i.available => i,
        _ => return Err("Check for updates first.".into()),
    };
    let path = updates::download(&info).await?;
    tauri_plugin_opener::open_path(path.to_string_lossy().to_string(), None::<&str>).map_err(|e| format!("Couldn't start the installer: {e}"))?;
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        std::thread::sleep(std::time::Duration::from_millis(1500));
        handle.exit(0);
    });
    Ok("The installer is starting. MacMint will close so it can update.".into())
}

#[tauri::command]
fn reveal_path(path: String) -> R<()> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err("It's not there anymore.".into());
    }
    tauri_plugin_opener::reveal_item_in_dir(&p).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_url(url: String) -> R<()> {
    let allowed = ["https://macmint.co", "https://github.com/QuntmTech/mac-mint", "https://support.microsoft.com"];
    if !allowed.iter().any(|a| url == *a || url.starts_with(&format!("{a}/")) || url.starts_with(&format!("{a}#"))) {
        return Err("That link isn't allowed.".into());
    }
    tauri_plugin_opener::open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let folders = KnownFolders::current();
    let data = folders.app_data.clone();
    let _ = std::fs::create_dir_all(&data);
    let settings = Settings::load(&data);
    let smart = std::fs::read(data.join("smart-scan.json")).ok().and_then(|d| serde_json::from_slice(&d).ok());
    // A move that was interrupted is recorded as "uncertain" in History, never as moved.
    let journal = data.join("journal.json");
    if let Some(report) = recover_journal(&journal) {
        if (HistoryStore { path: data.join("history.json") }).record(&report).is_ok() {
            let _ = std::fs::remove_file(&journal);
        }
    }
    let inner = Arc::new(Inner {
        policy: SafetyPolicy::new(folders),
        data,
        candidates: Mutex::new(HashMap::new()),
        plans: Mutex::new(HashMap::new()),
        apps: Mutex::new(vec![]),
        monitor: Mutex::new(Monitor::new()),
        lowered: Mutex::new(HashSet::new()),
        cancel_scan: AtomicBool::new(false),
        cancel_op: AtomicBool::new(false),
        operation_running: AtomicBool::new(false),
        smart: Mutex::new(smart),
        settings: Mutex::new(settings),
        account: tauri::async_runtime::Mutex::new(account::Account::default()),
        ai_history: Mutex::new(vec![]),
        pending_update: Mutex::new(None),
    });
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(inner.clone())
        .setup(move |_app| {
            let inner = inner.clone();
            tauri::async_runtime::spawn(async move {
                let device = inner.device();
                let mut a = inner.account.lock().await;
                a.start(&inner.data, &device).await;
                a.refresh_ai_status().await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app_info, get_overview, run_smart_scan, cancel_scan, scan_cleanup, scan_developer,
            list_apps, uninstall_app, find_leftovers, list_startup, set_startup_enabled, open_task_manager_startup,
            storage_breakdown, large_files, find_duplicates, old_downloads, performance, set_low_priority,
            prepare_plan, run_plan, cancel_operation, history, restore, empty_recycle_bin,
            get_settings, save_settings, account_status, sign_in, sign_out, refresh_account, ai_ask,
            check_updates, install_update, reveal_path, open_url
        ])
        .run(tauri::generate_context!())
        .expect("MacMint couldn't start");
}

#[allow(dead_code)]
fn _assert_manager(app: &AppHandle) {
    let _ = app.state::<Arc<Inner>>();
}
