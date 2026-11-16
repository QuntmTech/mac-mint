//! What the person picked, checked and normalized before anything moves.
use crate::fs::{comparison_key, is_inside_or_equal};
use crate::model::{CleanupCategory, CleanupTarget, Risk};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum ItemKind {
    Cleanup { category: CleanupCategory, risk: Risk },
    /// A file the person picked (large file, duplicate copy, download).
    ReviewedFile,
    /// A project or tool build folder.
    DeveloperArtifact,
    /// An app's leftover folder in AppData.
    AppLeftover,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanItem {
    pub id: String,
    pub path: PathBuf,
    pub name: String,
    pub kind: ItemKind,
    pub expected_bytes: u64,
    pub reason: String,
    pub source: String,
    /// Shown in the final check as needing a decision (review-level items, personal data).
    pub needs_attention: bool,
    /// Same item check at move time.
    pub identity: Option<String>,
    /// Lowercase executable names that write here; skipped while any is running.
    pub owner_processes: Vec<String>,
    /// A project folder whose tools and runtimes count as using this item.
    pub project_folder: Option<PathBuf>,
}

impl PlanItem {
    pub fn cleanup(target: &CleanupTarget) -> Self {
        Self {
            id: target.id.clone(),
            path: target.path.clone(),
            name: target.name.clone(),
            kind: ItemKind::Cleanup { category: target.category, risk: target.risk },
            expected_bytes: target.bytes,
            reason: target.reason.clone(),
            source: target.category.title().into(),
            needs_attention: target.risk != Risk::Safe,
            identity: crate::fs::identity(&target.path),
            owner_processes: target.owner_processes.clone().unwrap_or_default(),
            project_folder: None,
        }
    }

    pub fn reviewed_file(path: PathBuf, bytes: u64, source: &str, reason: &str) -> Self {
        Self {
            id: crate::model::path_id(&path),
            name: path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
            identity: crate::fs::identity(&path),
            path,
            kind: ItemKind::ReviewedFile,
            expected_bytes: bytes,
            reason: reason.into(),
            source: source.into(),
            needs_attention: true,
            owner_processes: vec![],
            project_folder: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rejection {
    pub path: PathBuf,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationPlan {
    pub title: String,
    pub items: Vec<PlanItem>,
    /// Picked but left out, with the reason (duplicates of another item, excluded, refused).
    pub rejected: Vec<Rejection>,
}

impl OperationPlan {
    pub fn total_bytes(&self) -> u64 {
        self.items.iter().map(|i| i.expected_bytes).sum()
    }
}

/// Builds a plan: drops duplicates and items inside another selected item (the outer one is
/// moved, so its contents aren't counted twice), and excluded paths.
pub fn plan(title: &str, items: Vec<PlanItem>, excluded: &[PathBuf]) -> OperationPlan {
    let mut sorted = items;
    sorted.sort_by_key(|i| comparison_key(&i.path).len());
    let mut kept: Vec<PlanItem> = Vec::new();
    let mut rejected = Vec::new();
    for item in sorted {
        if excluded.iter().any(|x| is_inside_or_equal(&item.path, x) || is_inside_or_equal(x, &item.path)) {
            rejected.push(Rejection { path: item.path.clone(), message: "Excluded in Settings, or contains something you excluded.".into() });
            continue;
        }
        if kept.iter().any(|k| is_inside_or_equal(&item.path, &k.path)) {
            continue;
        }
        kept.push(item);
    }
    OperationPlan { title: title.into(), items: kept, rejected }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(p: &str, bytes: u64) -> PlanItem {
        PlanItem::reviewed_file(PathBuf::from(p), bytes, "test", "test")
    }

    #[test]
    fn nested_and_duplicate_items_are_counted_once() {
        let p = plan("t", vec![item("/u/a/b", 5), item("/u/a", 10), item("/u/a", 10), item("/u/c", 1)], &[]);
        assert_eq!(p.items.len(), 2);
        assert_eq!(p.total_bytes(), 11);
    }

    #[test]
    fn exclusions_win_in_both_directions() {
        let p = plan("t", vec![item("/u/a", 10), item("/u/x/y", 3)], &[PathBuf::from("/u/a/keep"), PathBuf::from("/u/x")]);
        assert!(p.items.is_empty());
        assert_eq!(p.rejected.len(), 2);
    }
}
