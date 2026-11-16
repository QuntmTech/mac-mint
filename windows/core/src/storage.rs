//! Where the space went: folder sizes, large files, old downloads and duplicate files. Files
//! found here are always the person's own, so nothing is ever preselected.
use crate::fs::{is_link, measure, modified_secs, now_secs};
use crate::model::{Candidate, Found, Risk, ScanIssue, ScanReport};
use crate::plan::PlanItem;
use crate::safety::SafetyPolicy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderUsage {
    pub path: PathBuf,
    pub name: String,
    pub bytes: u64,
    pub is_dir: bool,
    pub files: u64,
    pub unreadable: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageBreakdown {
    pub path: PathBuf,
    pub bytes: u64,
    pub children: Vec<FolderUsage>,
}

/// Sizes of everything directly inside `path`, measured in parallel. Links are never followed.
pub fn breakdown(path: &Path, excluded: &[PathBuf]) -> Result<StorageBreakdown, String> {
    let entries: Vec<PathBuf> = std::fs::read_dir(path).map_err(|e| format!("Couldn't open this folder: {e}"))?.flatten().map(|e| e.path()).filter(|p| !is_link(p)).collect();
    let chunks = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8);
    let mut children: Vec<FolderUsage> = Vec::new();
    std::thread::scope(|s| {
        let handles: Vec<_> = entries
            .chunks(entries.len().div_ceil(chunks).max(1))
            .map(|chunk| {
                s.spawn(move || {
                    chunk.iter().map(|p| {
                        let m = measure(p, excluded);
                        FolderUsage { name: p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(), is_dir: p.is_dir(), bytes: m.bytes, files: m.files, unreadable: m.unreadable, path: p.clone() }
                    }).collect::<Vec<_>>()
                })
            })
            .collect();
        for h in handles {
            children.extend(h.join().unwrap_or_default());
        }
    });
    children.sort_by(|a, b| b.bytes.cmp(&a.bytes));
    Ok(StorageBreakdown { path: path.to_path_buf(), bytes: children.iter().map(|c| c.bytes).sum(), children })
}

/// Folders a personal-file search never enters: app data, system folders, tool caches.
fn skip_dir(name: &str) -> bool {
    let n = name.to_lowercase();
    n == "appdata" || n.starts_with('$') || n == "node_modules" || n == ".git" || n.starts_with('.') || n == "windows" || n == "program files" || n == "program files (x86)" || n == "programdata"
}

fn walk_files(root: &Path, excluded: &[PathBuf], cancel: &AtomicBool, mut visit: impl FnMut(&Path, &std::fs::Metadata)) -> (Vec<ScanIssue>, bool) {
    let mut issues = Vec::new();
    let mut walker = walkdir::WalkDir::new(root).follow_links(false).into_iter();
    while let Some(entry) = walker.next() {
        if cancel.load(Ordering::Relaxed) {
            return (issues, true);
        }
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                if e.depth() <= 2 {
                    if let Some(p) = e.path() {
                        issues.push(ScanIssue::new("Files", Some(p), "Couldn't open this folder."));
                    }
                }
                continue;
            }
        };
        let p = entry.path();
        if entry.depth() > 0 && entry.file_type().is_dir() {
            if skip_dir(&entry.file_name().to_string_lossy()) || is_link(p) || excluded.iter().any(|x| crate::fs::is_inside_or_equal(p, x)) {
                walker.skip_current_dir();
            }
            continue;
        }
        if entry.file_type().is_file() {
            if let Ok(m) = entry.metadata() {
                visit(p, &m);
            }
        }
    }
    (issues, false)
}

fn file_found(policy: &SafetyPolicy, path: &Path, bytes: u64, category: &str, group: &str, detail: String, reason: &str) -> Option<Found> {
    if !policy.reviewed_file(path).allowed() {
        return None;
    }
    let item = PlanItem::reviewed_file(path.to_path_buf(), bytes, group, reason);
    Some(Found {
        candidate: Candidate {
            id: item.id.clone(),
            path: path.to_path_buf(),
            name: item.name.clone(),
            group: group.into(),
            detail,
            bytes,
            risk: Risk::Review,
            reason: reason.into(),
            selected: false,
            blocked_by: None,
            owner_name: None,
            modified: modified_secs(path),
            category: category.into(),
        },
        item,
    })
}

fn folder_label(policy: &SafetyPolicy, path: &Path) -> String {
    let home = &policy.folders().home;
    path.parent().and_then(|p| p.strip_prefix(home).ok()).map(|p| p.display().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| "Home".into())
}

/// Files at least `min_bytes` big in the person's folders, largest first (at most 300).
pub fn large_files(policy: &SafetyPolicy, min_bytes: u64, excluded: &[PathBuf], cancel: &AtomicBool) -> ScanReport<Vec<Found>> {
    let mut found = Vec::new();
    let home = policy.folders().home.clone();
    let now = now_secs();
    let (issues, cancelled) = walk_files(&home, excluded, cancel, |p, m| {
        if m.len() >= min_bytes {
            let age = modified_secs(p).map(|t| now.saturating_sub(t) / 86_400).unwrap_or(0);
            let detail = format!("In {} · last changed {} days ago", folder_label(policy, p), age);
            if let Some(f) = file_found(policy, p, m.len(), "largeFile", "Large file", detail, "A big file you picked. Make sure you have a copy if you still need it.") {
                found.push(f);
            }
        }
    });
    found.sort_by(|a, b| b.candidate.bytes.cmp(&a.candidate.bytes));
    found.truncate(300);
    ScanReport { value: found, issues, cancelled }
}

/// Files in Downloads untouched for 90 days.
pub fn old_downloads(policy: &SafetyPolicy, excluded: &[PathBuf], cancel: &AtomicBool) -> ScanReport<Vec<Found>> {
    let mut found = Vec::new();
    let now = now_secs();
    let downloads = policy.folders().downloads.clone();
    let (issues, cancelled) = walk_files(&downloads, excluded, cancel, |p, m| {
        let age = modified_secs(p).map(|t| now.saturating_sub(t) / 86_400).unwrap_or(0);
        if age >= 90 {
            if let Some(f) = file_found(policy, p, m.len(), "download", "Downloads", format!("Downloaded {age} days ago"), "An old download. Keep it if you still use it.") {
                found.push(f);
            }
        }
    });
    found.sort_by(|a, b| b.candidate.bytes.cmp(&a.candidate.bytes));
    ScanReport { value: found, issues, cancelled }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DuplicateGroup {
    pub id: String,
    pub bytes: u64,
    pub files: Vec<Found>,
}

fn hash_file(path: &Path, limit: Option<u64>) -> Option<String> {
    let f = std::fs::File::open(path).ok()?;
    let mut reader: Box<dyn Read> = match limit {
        Some(n) => Box::new(f.take(n)),
        None => Box::new(f),
    };
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = reader.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Some(hex::encode(h.finalize()))
}

/// Byte-for-byte identical files of at least 1 MB, compared by size, then the first 64 KB, then
/// the whole file. The oldest copy in each group is marked as the one to keep.
pub fn duplicates(policy: &SafetyPolicy, excluded: &[PathBuf], cancel: &AtomicBool) -> ScanReport<Vec<DuplicateGroup>> {
    let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
    let home = policy.folders().home.clone();
    let (mut issues, cancelled) = walk_files(&home, excluded, cancel, |p, m| {
        if m.len() >= 1_000_000 {
            by_size.entry(m.len()).or_default().push(p.to_path_buf());
        }
    });
    if cancelled {
        return ScanReport { value: vec![], issues, cancelled };
    }
    let mut groups = Vec::new();
    for (size, paths) in by_size.into_iter().filter(|(_, v)| v.len() > 1) {
        if cancel.load(Ordering::Relaxed) {
            return ScanReport { value: groups, issues, cancelled: true };
        }
        let mut by_head: HashMap<String, Vec<PathBuf>> = HashMap::new();
        for p in paths {
            if let Some(h) = hash_file(&p, Some(65_536)) {
                by_head.entry(h).or_default().push(p);
            }
        }
        for (_, same_head) in by_head.into_iter().filter(|(_, v)| v.len() > 1) {
            let mut by_full: HashMap<String, Vec<PathBuf>> = HashMap::new();
            for p in same_head {
                match hash_file(&p, None) {
                    Some(h) => by_full.entry(h).or_default().push(p),
                    None => issues.push(ScanIssue::new("Duplicates", Some(&p), "Couldn't read this file to compare it.")),
                }
            }
            for (hash, mut copies) in by_full.into_iter().filter(|(_, v)| v.len() > 1) {
                copies.sort_by_key(|p| modified_secs(p).unwrap_or(u64::MAX));
                let files: Vec<Found> = copies.iter().enumerate().filter_map(|(i, p)| {
                    let detail = if i == 0 { format!("Oldest copy, in {}", folder_label(policy, p)) } else { format!("Copy in {}", folder_label(policy, p)) };
                    file_found(policy, p, size, "duplicate", "Duplicate", detail, "An identical copy of another file. One copy is always kept.")
                }).collect();
                if files.len() > 1 {
                    groups.push(DuplicateGroup { id: hash, bytes: size, files });
                }
            }
        }
    }
    groups.sort_by(|a, b| (b.bytes * (b.files.len() as u64 - 1)).cmp(&(a.bytes * (a.files.len() as u64 - 1))));
    ScanReport { value: groups, issues, cancelled: false }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::KnownFolders;

    #[test]
    fn finds_duplicates_large_files_and_skips_appdata() {
        let dir = tempfile::tempdir().unwrap();
        let f = KnownFolders::under(dir.path());
        let data = vec![9u8; 1_500_000];
        for p in ["Documents/a.bin", "Desktop/copy of a.bin", "AppData/Local/x/a.bin"] {
            let path = dir.path().join(p);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &data).unwrap();
        }
        let mut other = data.clone();
        other[1_400_000] = 1;
        std::fs::write(dir.path().join("Documents/near.bin"), &other).unwrap();
        let policy = SafetyPolicy::new(f);
        let d = duplicates(&policy, &[], &AtomicBool::new(false));
        assert_eq!(d.value.len(), 1);
        assert_eq!(d.value[0].files.len(), 2, "same bytes only; AppData ignored");
        let l = large_files(&policy, 1_000_000, &[], &AtomicBool::new(false));
        assert_eq!(l.value.len(), 3);
        assert!(l.value.iter().all(|x| !x.candidate.selected));
        let b = breakdown(dir.path(), &[]).unwrap();
        assert!(b.bytes >= 1_500_000 * 4);
    }
}
