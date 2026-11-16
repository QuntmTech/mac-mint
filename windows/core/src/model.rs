//! Shared data types. Mirrors MacCleanerCore's models so both apps reason the same way.
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Risk {
    /// Rebuilt or re-downloaded automatically, with an owner MacMint can check.
    Safe,
    /// Needs a person to look; never pre-selected.
    Review,
    /// Shown for awareness only; never moved.
    Restricted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CleanupCategory {
    /// Children of %TEMP% / %LOCALAPPDATA%\Temp.
    TempFiles,
    /// Named cache folders of known apps (browsers, Electron apps, launchers).
    AppCaches,
    /// Logs, crash dumps and Windows Error Reporting files: past records, review-only.
    LogsAndReports,
    /// Package-manager and build-tool caches.
    DeveloperCaches,
    /// Old installers and archives in Downloads.
    Installers,
}

impl CleanupCategory {
    pub fn title(self) -> &'static str {
        match self {
            Self::TempFiles => "Temporary files",
            Self::AppCaches => "App caches",
            Self::LogsAndReports => "Logs and crash reports",
            Self::DeveloperCaches => "Developer caches",
            Self::Installers => "Old installers",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupTarget {
    pub id: String,
    pub category: CleanupCategory,
    pub path: PathBuf,
    pub name: String,
    pub detail: String,
    pub bytes: u64,
    pub risk: Risk,
    pub reason: String,
    pub selected: bool,
    /// Executable names (lowercase, e.g. "chrome.exe") that write this data. Skipped while
    /// any of them runs. None means MacMint can't tell who uses it.
    pub owner_processes: Option<Vec<String>>,
    /// Human name of the owner for the UI.
    pub owner_name: Option<String>,
    /// Modified time in seconds since the epoch, when readable.
    pub modified: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanIssue {
    pub area: String,
    pub path: Option<String>,
    pub message: String,
}

impl ScanIssue {
    pub fn new(area: &str, path: Option<&std::path::Path>, message: impl Into<String>) -> Self {
        Self { area: area.into(), path: path.map(|p| p.display().to_string()), message: message.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanReport<T> {
    pub value: T,
    pub issues: Vec<ScanIssue>,
    pub cancelled: bool,
}

/// A stable id from a path, so selections survive rescans.
pub fn path_id(path: &std::path::Path) -> String {
    crate::fs::comparison_key(path)
}
