//! Project build folders. Generated output (target, .next, obj…) can be rebuilt; installed
//! dependencies (node_modules, .venv) can hold local edits or private packages, so they are only
//! ever offered for review, never suggested.
use crate::fs::{is_link, measure, modified_secs, now_secs};
use crate::model::{Risk, ScanIssue, ScanReport};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ArtifactKind {
    GeneratedOutput,
    InstalledDependencies,
}

struct Rule {
    name: &'static str,
    kind: ArtifactKind,
    /// Any of these files next to the folder proves which tool made it.
    markers: &'static [&'static str],
    /// Marker file extensions (for *.csproj and friends).
    marker_extensions: &'static [&'static str],
    tool: &'static str,
}

const RULES: &[Rule] = &[
    Rule { name: "node_modules", kind: ArtifactKind::InstalledDependencies, markers: &["package.json"], marker_extensions: &[], tool: "npm" },
    Rule { name: ".venv", kind: ArtifactKind::InstalledDependencies, markers: &["pyproject.toml", "requirements.txt", "Pipfile", "setup.py", "uv.lock"], marker_extensions: &[], tool: "Python" },
    Rule { name: "venv", kind: ArtifactKind::InstalledDependencies, markers: &["pyproject.toml", "requirements.txt", "Pipfile", "setup.py"], marker_extensions: &[], tool: "Python" },
    Rule { name: "target", kind: ArtifactKind::GeneratedOutput, markers: &["Cargo.toml"], marker_extensions: &[], tool: "Cargo" },
    Rule { name: ".next", kind: ArtifactKind::GeneratedOutput, markers: &["package.json"], marker_extensions: &[], tool: "Next.js" },
    Rule { name: ".nuxt", kind: ArtifactKind::GeneratedOutput, markers: &["package.json"], marker_extensions: &[], tool: "Nuxt" },
    Rule { name: ".turbo", kind: ArtifactKind::GeneratedOutput, markers: &["package.json"], marker_extensions: &[], tool: "Turborepo" },
    Rule { name: ".parcel-cache", kind: ArtifactKind::GeneratedOutput, markers: &["package.json"], marker_extensions: &[], tool: "Parcel" },
    Rule { name: ".svelte-kit", kind: ArtifactKind::GeneratedOutput, markers: &["package.json"], marker_extensions: &[], tool: "SvelteKit" },
    Rule { name: ".angular", kind: ArtifactKind::GeneratedOutput, markers: &["angular.json"], marker_extensions: &[], tool: "Angular" },
    Rule { name: "__pycache__", kind: ArtifactKind::GeneratedOutput, markers: &[], marker_extensions: &["py"], tool: "Python" },
    Rule { name: ".pytest_cache", kind: ArtifactKind::GeneratedOutput, markers: &[], marker_extensions: &[], tool: "pytest" },
    Rule { name: ".gradle", kind: ArtifactKind::GeneratedOutput, markers: &["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], marker_extensions: &[], tool: "Gradle" },
    Rule { name: "build", kind: ArtifactKind::GeneratedOutput, markers: &["build.gradle", "build.gradle.kts"], marker_extensions: &[], tool: "Gradle" },
    Rule { name: "obj", kind: ArtifactKind::GeneratedOutput, markers: &[], marker_extensions: &["csproj", "fsproj", "vbproj"], tool: ".NET" },
    Rule { name: "bin", kind: ArtifactKind::GeneratedOutput, markers: &[], marker_extensions: &["csproj", "fsproj", "vbproj"], tool: ".NET" },
];

fn rule_for(path: &Path) -> Option<&'static Rule> {
    let name = path.file_name()?.to_string_lossy().to_lowercase();
    let parent = path.parent()?;
    RULES.iter().find(|r| {
        r.name.eq_ignore_ascii_case(&name) && (has_marker(parent, r) || (r.name == ".pytest_cache"))
    })
}

fn has_marker(folder: &Path, rule: &Rule) -> bool {
    if rule.markers.iter().any(|m| folder.join(m).is_file()) {
        return true;
    }
    if rule.marker_extensions.is_empty() {
        return false;
    }
    std::fs::read_dir(folder).map(|entries| {
        entries.flatten().take(500).any(|e| {
            let p = e.path();
            p.is_file() && p.extension().map(|x| rule.marker_extensions.iter().any(|m| x.eq_ignore_ascii_case(m))).unwrap_or(false)
        })
    }).unwrap_or(false)
}

/// A known build folder sitting next to the project file of the tool that makes it.
pub fn is_project_artifact(path: &Path) -> bool {
    !is_link(path) && path.is_dir() && rule_for(path).is_some()
}

/// Signs that installed packages were edited locally, so reinstalling might lose work.
fn patch_markers(project: &Path) -> Option<String> {
    if project.join("patches").is_dir() {
        return Some("This project has a patches folder; reinstalling may not bring local fixes back.".into());
    }
    if let Ok(pkg) = std::fs::read_to_string(project.join("package.json")) {
        if pkg.contains("patch-package") || pkg.contains("\"patchedDependencies\"") {
            return Some("This project patches its packages; reinstalling may not bring local fixes back.".into());
        }
        if pkg.contains("\"file:") || pkg.contains("\"link:") {
            return Some("This project uses local packages that may not be reinstallable.".into());
        }
    }
    None
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperItem {
    pub id: String,
    pub path: PathBuf,
    pub project: PathBuf,
    pub project_name: String,
    pub name: String,
    pub tool: String,
    pub kind: ArtifactKind,
    pub bytes: u64,
    pub risk: Risk,
    pub detail: String,
    /// Last change anywhere in the project's top level, in seconds since 1970.
    pub last_activity: Option<u64>,
    /// Suggested for a one-click cleanup: generated output in a project idle for 30+ days.
    pub suggested: bool,
    pub identity: Option<String>,
}

const SKIP_DIRS: &[&str] = &["appdata", "$recycle.bin", "windows", "program files", "program files (x86)", "programdata", ".git", ".hg", ".svn", "onedrive", "pictures", "music", "videos"];

/// Walks the given roots (normally the home folder) up to `max_depth` looking for build folders.
/// Never descends into a found artifact, a link, or system folders.
pub fn scan_projects(roots: &[PathBuf], max_depth: usize, excluded: &[PathBuf], cancel: &AtomicBool) -> ScanReport<Vec<DeveloperItem>> {
    let mut items = Vec::new();
    let mut issues = Vec::new();
    let now = now_secs();
    for root in roots {
        let mut walker = walkdir::WalkDir::new(root).max_depth(max_depth).follow_links(false).into_iter();
        while let Some(entry) = walker.next() {
            if cancel.load(Ordering::Relaxed) {
                return ScanReport { value: items, issues, cancelled: true };
            }
            let entry = match entry {
                Ok(e) => e,
                Err(e) => {
                    if e.depth() <= 2 {
                        if let Some(p) = e.path() {
                            issues.push(ScanIssue::new("Developer", Some(p), "Couldn't open this folder."));
                        }
                    }
                    continue;
                }
            };
            if !entry.file_type().is_dir() || entry.depth() == 0 {
                continue;
            }
            let path = entry.path();
            let lower = entry.file_name().to_string_lossy().to_lowercase();
            if is_link(path) || excluded.iter().any(|x| crate::fs::is_inside_or_equal(path, x)) {
                walker.skip_current_dir();
                continue;
            }
            if SKIP_DIRS.contains(&lower.as_str()) {
                walker.skip_current_dir();
                continue;
            }
            let Some(rule) = rule_for(path) else {
                // Hidden folders other than artifacts are tool data; don't wander into them.
                if lower.starts_with('.') {
                    walker.skip_current_dir();
                }
                continue;
            };
            walker.skip_current_dir();
            let project = path.parent().unwrap().to_path_buf();
            let m = measure(path, excluded);
            if m.bytes < 1_000_000 {
                continue;
            }
            let last_activity = latest_top_level_change(&project);
            let idle_days = last_activity.map(|t| now.saturating_sub(t) / 86_400);
            let (risk, detail, suggested) = match rule.kind {
                ArtifactKind::InstalledDependencies => {
                    let mut d = String::from("Installed packages. Reinstalling may not restore local edits or private packages.");
                    if let Some(p) = patch_markers(&project) {
                        d = p;
                    }
                    (Risk::Review, d, false)
                }
                ArtifactKind::GeneratedOutput => {
                    let idle = idle_days.map(|d| d >= 30).unwrap_or(false);
                    let detail = match idle_days {
                        Some(d) if d >= 30 => format!("{} build output. The project hasn't changed in {d} days; it rebuilds next time.", rule.tool),
                        Some(_) => format!("{} build output. The project changed recently, so it's left for you to decide.", rule.tool),
                        None => format!("{} build output.", rule.tool),
                    };
                    (Risk::Safe, detail, idle && m.unreadable == 0)
                }
            };
            items.push(DeveloperItem {
                id: crate::model::path_id(path),
                project_name: project.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
                name: entry.file_name().to_string_lossy().to_string(),
                path: path.to_path_buf(),
                project,
                tool: rule.tool.into(),
                kind: rule.kind,
                bytes: m.bytes,
                risk,
                detail,
                last_activity,
                suggested,
                identity: crate::fs::identity(path),
            });
        }
    }
    items.sort_by(|a, b| b.bytes.cmp(&a.bytes));
    ScanReport { value: items, issues, cancelled: false }
}

/// The newest change among the project's own files (artifact folders excluded).
fn latest_top_level_change(project: &Path) -> Option<u64> {
    let mut newest = None;
    let entries = std::fs::read_dir(project).ok()?;
    for e in entries.flatten().take(2000) {
        let p = e.path();
        if rule_for(&p).is_some() {
            continue;
        }
        if let Some(t) = modified_secs(&p) {
            newest = Some(newest.map_or(t, |n: u64| n.max(t)));
        }
    }
    newest
}

#[cfg(test)]
mod tests {
    use super::*;

    fn big(path: &Path) {
        std::fs::create_dir_all(path).unwrap();
        std::fs::write(path.join("blob"), vec![0u8; 1_200_000]).unwrap();
    }

    #[test]
    fn recognizes_artifacts_only_next_to_their_project_file() {
        let dir = tempfile::tempdir().unwrap();
        let rust = dir.path().join("app");
        big(&rust.join("target"));
        std::fs::write(rust.join("Cargo.toml"), "").unwrap();
        let loose = dir.path().join("loose");
        big(&loose.join("target"));
        big(&loose.join("bin"));
        assert!(is_project_artifact(&rust.join("target")));
        assert!(!is_project_artifact(&loose.join("target")));
        assert!(!is_project_artifact(&loose.join("bin")));
    }

    #[test]
    fn dependencies_are_review_and_never_suggested() {
        let dir = tempfile::tempdir().unwrap();
        let web = dir.path().join("Projects/web");
        big(&web.join("node_modules"));
        std::fs::write(web.join("package.json"), r#"{"scripts":{"postinstall":"patch-package"}}"#).unwrap();
        let report = scan_projects(&[dir.path().to_path_buf()], 6, &[], &AtomicBool::new(false));
        assert_eq!(report.value.len(), 1);
        let item = &report.value[0];
        assert_eq!(item.risk, Risk::Review);
        assert!(!item.suggested);
        assert!(item.detail.contains("patches"));
    }

    #[test]
    fn recent_generated_output_is_not_suggested_and_appdata_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let rust = dir.path().join("Projects/app");
        big(&rust.join("target"));
        std::fs::write(rust.join("Cargo.toml"), "").unwrap();
        let hidden = dir.path().join("AppData/Local/thing");
        big(&hidden.join("target"));
        std::fs::write(hidden.join("Cargo.toml"), "").unwrap();
        let report = scan_projects(&[dir.path().to_path_buf()], 8, &[], &AtomicBool::new(false));
        assert_eq!(report.value.len(), 1);
        assert_eq!(report.value[0].risk, Risk::Safe);
        assert!(!report.value[0].suggested, "changed today, so not suggested");
    }
}
