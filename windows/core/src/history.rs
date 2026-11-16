//! Every completed operation, with what can still be put back.
use crate::executor::{write_durably, OperationReport, OutcomeStatus};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: String,
    pub title: String,
    pub date: u64,
    pub bytes: u64,
    pub receipts: Vec<crate::trash::TrashReceipt>,
    /// Original paths already put back.
    pub restored: Vec<PathBuf>,
    pub notes: String,
    /// Moves that were interrupted and can't be confirmed.
    pub uncertain: Vec<PathBuf>,
}

pub struct HistoryStore {
    pub path: PathBuf,
}

impl HistoryStore {
    pub fn load(&self) -> Result<Vec<HistoryEntry>, String> {
        match std::fs::read(&self.path) {
            Ok(data) => serde_json::from_slice(&data).map_err(|e| format!("History couldn't be read and was left untouched: {e}")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
            Err(e) => Err(e.to_string()),
        }
    }

    fn save(&self, entries: &[HistoryEntry]) -> Result<(), String> {
        write_durably(&self.path, &serde_json::to_vec_pretty(entries).map_err(|e| e.to_string())?)
    }

    /// Adds an operation once (by id). A corrupt history file is never overwritten.
    pub fn record(&self, report: &OperationReport) -> Result<(), String> {
        let mut entries = self.load()?;
        if entries.iter().any(|e| e.id == report.id) {
            return Ok(());
        }
        let receipts: Vec<_> = report.moved().filter_map(|o| o.receipt.clone()).collect();
        let uncertain: Vec<_> = report.outcomes.iter().filter(|o| o.status == OutcomeStatus::Uncertain).map(|o| o.item.path.clone()).collect();
        if receipts.is_empty() && uncertain.is_empty() {
            return Ok(());
        }
        entries.insert(0, HistoryEntry {
            id: report.id.clone(),
            title: report.title.clone(),
            date: report.started_at,
            bytes: report.bytes_moved(),
            receipts,
            restored: vec![],
            notes: report.summary(),
            uncertain,
        });
        self.save(&entries)
    }

    pub fn mark_restored(&self, entry_id: &str, original: &std::path::Path) -> Result<(), String> {
        let mut entries = self.load()?;
        if let Some(e) = entries.iter_mut().find(|e| e.id == entry_id) {
            if !e.restored.iter().any(|p| crate::fs::comparison_key(p) == crate::fs::comparison_key(original)) {
                e.restored.push(original.to_path_buf());
            }
        }
        self.save(&entries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::executor::{ItemOutcome, OperationReport};
    use crate::plan::PlanItem;
    use crate::trash::TrashReceipt;

    #[test]
    fn records_once_and_never_overwrites_a_corrupt_file() {
        let dir = tempfile::tempdir().unwrap();
        let store = HistoryStore { path: dir.path().join("history.json") };
        let item = PlanItem::reviewed_file(dir.path().join("a"), 10, "t", "t");
        let report = OperationReport {
            id: "op1".into(), title: "t".into(), started_at: 5, finished_at: Some(6),
            outcomes: vec![ItemOutcome { item: item.clone(), status: OutcomeStatus::Moved, message: None,
                receipt: Some(TrashReceipt { original_path: item.path.clone(), bytes: 10, trashed_at: 5, trash_id: None }) }],
            cancelled: false, interrupted: false,
        };
        store.record(&report).unwrap();
        store.record(&report).unwrap();
        assert_eq!(store.load().unwrap().len(), 1);
        std::fs::write(&store.path, b"{not json").unwrap();
        assert!(store.record(&report).is_err());
        assert_eq!(std::fs::read(&store.path).unwrap(), b"{not json");
    }
}
