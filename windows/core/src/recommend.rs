//! Turns scan results into plain-words recommendations. Only claims what was actually checked:
//! unknown owners and personal data are review-only, open apps are named, and areas that ran
//! with problems are reported as partly checked.
use crate::developer::{ArtifactKind, DeveloperItem};
use crate::fs::format_bytes;
use crate::model::{Found, Risk, ScanIssue};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanArea {
    pub id: String,
    pub title: String,
    /// "checked" | "partial" | "failed" | "skipped"
    pub status: String,
    pub bytes_found: u64,
    pub note: Option<String>,
}

impl ScanArea {
    pub fn from(id: &str, title: &str, bytes: u64, issues: &[ScanIssue], cancelled: bool) -> Self {
        let (status, note) = if cancelled {
            ("skipped", Some("Stopped before it finished.".to_string()))
        } else if issues.is_empty() {
            ("checked", None)
        } else {
            ("partial", Some(format!("{} place{} couldn't be read.", issues.len(), if issues.len() == 1 { "" } else { "s" })))
        };
        Self { id: id.into(), title: title.into(), status: status.into(), bytes_found: bytes, note }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Recommendation {
    pub id: String,
    pub title: String,
    pub detail: String,
    pub bytes: u64,
    pub candidate_ids: Vec<String>,
    /// "clean" | "review" | "advice"
    pub kind: String,
    pub page: String,
    pub tone: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SmartScan {
    pub checked_at: u64,
    pub areas: Vec<ScanArea>,
    pub recommendations: Vec<Recommendation>,
    pub reclaimable_bytes: u64,
}

pub struct Inputs<'a> {
    pub cleanup: &'a [Found],
    pub developer: &'a [DeveloperItem],
    pub leftovers: &'a [Found],
    pub startup_enabled: usize,
    pub system_disk: Option<(u64, u64)>, // (total, free)
    pub recycle_bin_bytes: u64,
}

fn rec(id: &str, title: String, detail: String, bytes: u64, ids: Vec<String>, kind: &str, page: &str, tone: &str) -> Recommendation {
    Recommendation { id: id.into(), title, detail, bytes, candidate_ids: ids, kind: kind.into(), page: page.into(), tone: tone.into() }
}

fn plural(n: usize, one: &str) -> String {
    if n == 1 { format!("1 {one}") } else { format!("{n} {one}s") }
}

pub fn recommendations(input: &Inputs) -> Vec<Recommendation> {
    let mut out = Vec::new();

    // 1. Safe, owner known (or none needed), owner not running.
    let ready: Vec<&Found> = input.cleanup.iter().filter(|f| f.candidate.selected).collect();
    if !ready.is_empty() {
        let bytes = ready.iter().map(|f| f.candidate.bytes).sum();
        let groups: std::collections::BTreeSet<_> = ready.iter().map(|f| f.candidate.group.clone()).collect();
        let names: Vec<_> = groups.into_iter().take(4).collect();
        out.push(rec("rebuildable", format!("Clear {} of temporary files and caches", format_bytes(bytes)),
            format!("From {}. These rebuild themselves. Apps that are open are skipped.", names.join(", ")),
            bytes, ready.iter().map(|f| f.candidate.id.clone()).collect(), "clean", "cleanup", "mint"));
    }

    // 2. Caches whose app is open: never selected, but worth knowing about.
    let open: Vec<&Found> = input.cleanup.iter().filter(|f| f.candidate.blocked_by.is_some() && f.candidate.risk == Risk::Safe).collect();
    if !open.is_empty() {
        let bytes = open.iter().map(|f| f.candidate.bytes).sum();
        let apps: std::collections::BTreeSet<_> = open.iter().filter_map(|f| f.candidate.owner_name.clone()).collect();
        out.push(rec("close-first", format!("{} more after you close {}", format_bytes(bytes), apps.iter().cloned().collect::<Vec<_>>().join(", ")),
            "These caches belong to apps that are open right now. MacMint never closes your apps; close them and scan again.".into(),
            bytes, vec![], "advice", "cleanup", "sky"));
    }

    // 3. Old build output in idle projects.
    let idle: Vec<&DeveloperItem> = input.developer.iter().filter(|d| d.suggested).collect();
    if !idle.is_empty() {
        let bytes = idle.iter().map(|d| d.bytes).sum();
        out.push(rec("build-output", format!("Remove {} of old build output", format_bytes(bytes)),
            format!("From {} idle for 30+ days. It's rebuilt the next time you build.", plural(idle.len(), "project")),
            bytes, idle.iter().map(|d| d.id.clone()).collect(), "clean", "developer", "violet"));
    }

    // 4. Review-only cleanup: logs, installers, unknown owners, review-level tools.
    let review: Vec<&Found> = input.cleanup.iter().filter(|f| f.candidate.risk == Risk::Review).collect();
    if !review.is_empty() {
        let bytes = review.iter().map(|f| f.candidate.bytes).sum();
        let unknown = review.iter().filter(|f| f.candidate.category == "appCaches" && f.candidate.owner_name.is_none()).count();
        let mut detail = "Crash reports, old installers and data MacMint can't vouch for. Nothing is picked for you.".to_string();
        if unknown > 0 {
            detail.push_str(&format!(" Ownership couldn't be confirmed for {}.", plural(unknown, "cache")));
        }
        out.push(rec("review-cleanup", format!("Review {} you might not need", format_bytes(bytes)), detail, bytes, vec![], "review", "cleanup", "amber"));
    }

    // 5. Installed packages: never suggested.
    let deps: Vec<&DeveloperItem> = input.developer.iter().filter(|d| d.kind == ArtifactKind::InstalledDependencies).collect();
    if !deps.is_empty() {
        let bytes = deps.iter().map(|d| d.bytes).sum();
        out.push(rec("dependencies", format!("{} of installed packages in {}", format_bytes(bytes), plural(deps.len(), "project")),
            "node_modules and Python environments can hold local edits or private packages, so they're yours to review.".into(),
            bytes, vec![], "review", "developer", "slate"));
    }

    // 6. AppData with no owner found.
    if !input.leftovers.is_empty() {
        let bytes = input.leftovers.iter().map(|f| f.candidate.bytes).sum();
        out.push(rec("leftovers", format!("App data with no owner found: {}", format_bytes(bytes)),
            format!("{} in AppData didn't match any installed app. They may be from apps you removed. Review one at a time.", plural(input.leftovers.len(), "folder")),
            bytes, vec![], "review", "apps", "slate"));
    }

    // 7. Startup.
    if input.startup_enabled >= 6 {
        out.push(rec("startup", format!("{} apps start with Windows", input.startup_enabled),
            "Turning off ones you don't need right away can make sign-in faster. You can turn them back on anytime.".into(),
            0, vec![], "advice", "startup", "sky"));
    }

    // 8. Space.
    if let Some((total, free)) = input.system_disk {
        if total > 0 && free * 10 < total {
            out.push(rec("low-space", format!("Only {} free on your system drive", format_bytes(free)),
                "Windows needs room for updates. Look at Storage to see what's using the most.".into(), 0, vec![], "advice", "storage", "amber"));
        }
    }
    if input.recycle_bin_bytes >= 500_000_000 {
        out.push(rec("recycle-bin", format!("The Recycle Bin holds {}", format_bytes(input.recycle_bin_bytes)),
            "Space comes back only when it's emptied. Check History first if you might want something back.".into(),
            0, vec![], "advice", "history", "slate"));
    }
    out
}

pub fn reclaimable(recs: &[Recommendation]) -> u64 {
    recs.iter().filter(|r| r.kind == "clean").map(|r| r.bytes).sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Candidate;
    use crate::plan::PlanItem;

    fn found(id: &str, risk: Risk, selected: bool, blocked: bool, owner: Option<&str>) -> Found {
        let path = std::path::PathBuf::from(format!("/h/{id}"));
        Found {
            candidate: Candidate { id: id.into(), path: path.clone(), name: id.into(), group: "G".into(), detail: String::new(), bytes: 1000, risk, reason: String::new(), selected, blocked_by: blocked.then(|| "open".into()), owner_name: owner.map(String::from), modified: None, category: "appCaches".into() },
            item: PlanItem::reviewed_file(path, 1000, "t", "t"),
        }
    }

    #[test]
    fn only_selected_items_count_as_reclaimable() {
        let cleanup = vec![
            found("a", Risk::Safe, true, false, Some("Chrome")),
            found("b", Risk::Safe, false, true, Some("Code")),
            found("c", Risk::Review, false, false, None),
        ];
        let recs = recommendations(&Inputs { cleanup: &cleanup, developer: &[], leftovers: &[], startup_enabled: 2, system_disk: Some((100, 50)), recycle_bin_bytes: 0 });
        assert_eq!(reclaimable(&recs), 1000);
        let first = &recs[0];
        assert_eq!(first.candidate_ids, vec!["a".to_string()]);
        assert!(recs.iter().any(|r| r.id == "close-first" && r.candidate_ids.is_empty()));
        let review = recs.iter().find(|r| r.id == "review-cleanup").unwrap();
        assert!(review.detail.contains("couldn't be confirmed for 1 cache"));
    }

    #[test]
    fn partial_areas_are_reported() {
        let a = ScanArea::from("x", "X", 0, &[ScanIssue::new("X", None, "no")], false);
        assert_eq!(a.status, "partial");
        assert_eq!(ScanArea::from("x", "X", 0, &[], true).status, "skipped");
    }
}
