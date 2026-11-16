//! Runs a reviewed plan: each item is checked again right before it moves (still there, same
//! item, still allowed, nothing using it), moved to the Recycle Bin, and recorded. A journal is
//! written before every move, so an interrupted run can still be explained and restored.
use crate::fs::{identity, measure};
use crate::plan::{ItemKind, OperationPlan, PlanItem};
use crate::process::{conflict, ProcessSource};
use crate::safety::{Decision, SafetyPolicy};
use crate::trash::{TrashReceipt, TrashService};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutcomeStatus {
    Moved,
    Skipped,
    Failed,
    NotAttempted,
    /// The move had started when MacMint stopped; resolved on the next launch.
    InFlight,
    /// Interrupted before the result could be recorded. Never shown as moved.
    Uncertain,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemOutcome {
    pub item: PlanItem,
    pub status: OutcomeStatus,
    pub message: Option<String>,
    pub receipt: Option<TrashReceipt>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationReport {
    pub id: String,
    pub title: String,
    pub started_at: u64,
    pub finished_at: Option<u64>,
    pub outcomes: Vec<ItemOutcome>,
    pub cancelled: bool,
    pub interrupted: bool,
}

impl OperationReport {
    pub fn moved(&self) -> impl Iterator<Item = &ItemOutcome> {
        self.outcomes.iter().filter(|o| o.status == OutcomeStatus::Moved)
    }
    pub fn bytes_moved(&self) -> u64 {
        self.moved().filter_map(|o| o.receipt.as_ref()).map(|r| r.bytes).sum()
    }
    /// Honest summary: space comes back only when the Recycle Bin is emptied.
    pub fn summary(&self) -> String {
        let n = self.moved().count();
        let skipped = self.outcomes.iter().filter(|o| matches!(o.status, OutcomeStatus::Skipped | OutcomeStatus::Failed)).count();
        let mut s = format!(
            "{n} item{} {} in the Recycle Bin · {}",
            if n == 1 { "" } else { "s" },
            if n == 1 { "is" } else { "are" },
            crate::fs::format_bytes(self.bytes_moved())
        );
        if skipped > 0 {
            s.push_str(&format!(" · {skipped} left in place"));
        }
        s
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub completed: usize,
    pub total: usize,
    pub bytes_moved: u64,
}

pub struct Executor<'a> {
    pub policy: &'a SafetyPolicy,
    pub trash: &'a dyn TrashService,
    pub processes: &'a dyn ProcessSource,
    pub journal: Option<PathBuf>,
    pub excluded: Vec<PathBuf>,
}

impl<'a> Executor<'a> {
    pub fn run(&self, plan: &OperationPlan, cancel: &AtomicBool, mut progress: impl FnMut(Progress)) -> OperationReport {
        let mut report = OperationReport {
            id: format!("op-{}-{}", crate::fs::now_secs(), plan.items.len()),
            title: plan.title.clone(),
            started_at: crate::fs::now_secs(),
            finished_at: None,
            outcomes: plan.items.iter().map(|i| ItemOutcome { item: i.clone(), status: OutcomeStatus::NotAttempted, message: None, receipt: None }).collect(),
            cancelled: false,
            interrupted: false,
        };
        let mut bytes_moved = 0u64;
        // One reading of what's running, refreshed every two seconds rather than per item.
        let mut snapshot: Option<(std::time::Instant, Result<Vec<crate::process::ActiveProcess>, String>)> = None;
        let mut processes = || {
            if snapshot.as_ref().map(|(t, _)| t.elapsed().as_secs() < 2) != Some(true) {
                snapshot = Some((std::time::Instant::now(), self.processes.processes()));
            }
            snapshot.as_ref().unwrap().1.clone()
        };
        for (index, item) in plan.items.iter().enumerate() {
            if cancel.load(Ordering::SeqCst) {
                report.cancelled = true;
                break;
            }
            progress(Progress { completed: index, total: plan.items.len(), bytes_moved });
            if let Some(reason) = self.validate(item, &processes()) {
                report.outcomes[index].status = OutcomeStatus::Skipped;
                report.outcomes[index].message = Some(reason);
                continue;
            }
            report.outcomes[index].status = OutcomeStatus::InFlight;
            if let Err(e) = self.write_journal(&report) {
                report.outcomes[index].status = OutcomeStatus::NotAttempted;
                report.outcomes[index].message = Some(format!("Couldn't record the move first, so nothing was moved: {e}"));
                break;
            }
            // Sizing can take a while: check everything again after it.
            let size = measure(&item.path, &[]).bytes;
            if let Some(reason) = self.validate(item, &processes()) {
                report.outcomes[index].status = OutcomeStatus::Skipped;
                report.outcomes[index].message = Some(reason);
                continue;
            }
            match self.trash.trash(&item.path, size) {
                Ok(receipt) => {
                    bytes_moved += receipt.bytes;
                    report.outcomes[index].status = OutcomeStatus::Moved;
                    report.outcomes[index].receipt = Some(receipt);
                }
                Err(e) => {
                    report.outcomes[index].status = OutcomeStatus::Failed;
                    report.outcomes[index].message = Some(format!("Couldn't move it to the Recycle Bin: {e}"));
                }
            }
        }
        report.finished_at = Some(crate::fs::now_secs());
        progress(Progress { completed: plan.items.len(), total: plan.items.len(), bytes_moved });
        let _ = self.write_journal(&report);
        report
    }

    /// A reason to leave the item in place, or None to move it.
    fn validate(&self, item: &PlanItem, processes: &Result<Vec<crate::process::ActiveProcess>, String>) -> Option<String> {
        if self.excluded.iter().any(|x| crate::fs::is_inside_or_equal(&item.path, x) || crate::fs::is_inside_or_equal(x, &item.path)) {
            return Some("Excluded in Settings.".into());
        }
        if std::fs::symlink_metadata(&item.path).is_err() {
            return Some("No longer exists; it may already have been removed.".into());
        }
        if let Some(expected) = &item.identity {
            if identity(&item.path).as_ref() != Some(expected) {
                return Some("A different item is at this place now. Scan again before removing it.".into());
            }
        }
        let decision = match item.kind {
            ItemKind::Cleanup { category, .. } => self.policy.cleanup(&item.path, category),
            ItemKind::ReviewedFile => self.policy.reviewed_file(&item.path),
            ItemKind::DeveloperArtifact => self.policy.developer_artifact(&item.path),
            ItemKind::AppLeftover => self.policy.app_leftover(&item.path),
        };
        if let Decision::Refused(reason) = decision {
            return Some(reason);
        }
        match processes {
            Ok(list) => conflict(&item.path, &item.owner_processes, item.project_folder.as_deref(), list),
            // Can't see what's running: anything an app or build tool might be using stays.
            Err(_) if !item.owner_processes.is_empty() || item.project_folder.is_some() => {
                Some("Couldn't confirm nothing is using it right now, so it was left in place.".into())
            }
            Err(_) => None,
        }
    }

    fn write_journal(&self, report: &OperationReport) -> Result<(), String> {
        let Some(path) = &self.journal else { return Ok(()) };
        write_durably(path, &serde_json::to_vec_pretty(report).map_err(|e| e.to_string())?)
    }
}

/// Write to a temporary file, flush, then replace: a crash never leaves half a file.
pub fn write_durably(path: &Path, data: &[u8]) -> Result<(), String> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    f.write_all(data).map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// After a crash: anything still in flight becomes "uncertain" (never "moved") and is kept for
/// History, so the person can check the Recycle Bin.
pub fn recover_journal(path: &Path) -> Option<OperationReport> {
    let data = std::fs::read(path).ok()?;
    let mut report: OperationReport = serde_json::from_slice(&data).ok()?;
    let mut changed = false;
    for o in &mut report.outcomes {
        if o.status == OutcomeStatus::InFlight {
            o.status = OutcomeStatus::Uncertain;
            o.message = Some("MacMint stopped while moving this. Check the Recycle Bin.".into());
            changed = true;
        }
    }
    if report.finished_at.is_none() {
        report.interrupted = true;
        changed = true;
    }
    let _ = changed;
    Some(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CleanupCategory, Risk};
    use crate::paths::KnownFolders;
    use crate::process::{ActiveProcess, FixedProcesses};
    use crate::trash::FolderTrash;

    fn setup() -> (tempfile::TempDir, SafetyPolicy, FolderTrash) {
        let dir = tempfile::tempdir().unwrap();
        let folders = KnownFolders::under(dir.path());
        std::fs::create_dir_all(&folders.temp).unwrap();
        let trash = FolderTrash { folder: dir.path().join("RecycleBin") };
        (dir, SafetyPolicy::new(folders), trash)
    }

    fn temp_item(dir: &Path, name: &str, owners: Vec<String>) -> PlanItem {
        let path = dir.join("AppData/Local/Temp").join(name);
        std::fs::create_dir_all(&path).unwrap();
        std::fs::write(path.join("f.bin"), vec![1u8; 2048]).unwrap();
        PlanItem {
            id: name.into(),
            name: name.into(),
            identity: identity(&path),
            path,
            kind: ItemKind::Cleanup { category: CleanupCategory::TempFiles, risk: Risk::Safe },
            expected_bytes: 2048,
            reason: "t".into(),
            source: "t".into(),
            needs_attention: false,
            owner_processes: owners,
            project_folder: None,
        }
    }

    #[test]
    fn moves_to_the_recycle_bin_and_restores() {
        let (dir, policy, trash) = setup();
        let item = temp_item(dir.path(), "setup1", vec![]);
        let plan = crate::plan::plan("t", vec![item.clone()], &[]);
        let exec = Executor { policy: &policy, trash: &trash, processes: &FixedProcesses(vec![]), journal: Some(dir.path().join("journal.json")), excluded: vec![] };
        let report = exec.run(&plan, &AtomicBool::new(false), |_| {});
        assert_eq!(report.outcomes[0].status, OutcomeStatus::Moved);
        assert!(!item.path.exists());
        assert!(report.summary().contains("in the Recycle Bin"));
        trash.restore(report.outcomes[0].receipt.as_ref().unwrap()).unwrap();
        assert!(item.path.join("f.bin").exists());
    }

    #[test]
    fn open_owner_replaced_item_and_refused_paths_stay() {
        let (dir, policy, trash) = setup();
        let owned = temp_item(dir.path(), "owned", vec!["app.exe".into()]);
        let mut replaced = temp_item(dir.path(), "replaced", vec![]);
        replaced.identity = Some("d:0".into());
        let mut outside = temp_item(dir.path(), "outside", vec![]);
        outside.path = dir.path().join("Documents/notes");
        std::fs::create_dir_all(&outside.path).unwrap();
        let plan = crate::plan::plan("t", vec![owned.clone(), replaced.clone(), outside.clone()], &[]);
        let procs = FixedProcesses(vec![ActiveProcess { pid: 1, name: "app.exe".into(), working_directory: None, exe: None }]);
        let exec = Executor { policy: &policy, trash: &trash, processes: &procs, journal: None, excluded: vec![] };
        let report = exec.run(&plan, &AtomicBool::new(false), |_| {});
        assert!(report.outcomes.iter().all(|o| o.status == OutcomeStatus::Skipped));
        assert!(owned.path.exists() && replaced.path.exists() && outside.path.exists());
    }

    #[test]
    fn an_interrupted_journal_is_recovered_as_uncertain() {
        let (dir, _policy, _trash) = setup();
        let item = temp_item(dir.path(), "x", vec![]);
        let report = OperationReport {
            id: "op".into(), title: "t".into(), started_at: 1, finished_at: None,
            outcomes: vec![ItemOutcome { item, status: OutcomeStatus::InFlight, message: None, receipt: None }],
            cancelled: false, interrupted: false,
        };
        let path = dir.path().join("journal.json");
        write_durably(&path, &serde_json::to_vec(&report).unwrap()).unwrap();
        let recovered = recover_journal(&path).unwrap();
        assert_eq!(recovered.outcomes[0].status, OutcomeStatus::Uncertain);
        assert!(recovered.interrupted);
    }
}
