//! Preferences, saved as JSON in MacMint's data folder.
use macmint_core::executor::write_durably;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub theme: String,
    pub exclusions: Vec<String>,
    pub has_onboarded: bool,
    pub has_taken_tour: bool,
    pub ai_enabled: bool,
    pub check_updates_automatically: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self { theme: "system".into(), exclusions: vec![], has_onboarded: false, has_taken_tour: false, ai_enabled: false, check_updates_automatically: true }
    }
}

impl Settings {
    pub fn load(dir: &Path) -> Self {
        std::fs::read(dir.join("settings.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    pub fn save(&self, dir: &Path) -> Result<(), String> {
        write_durably(&dir.join("settings.json"), &serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?)
    }

    pub fn excluded_paths(&self) -> Vec<PathBuf> {
        self.exclusions.iter().filter(|s| !s.trim().is_empty()).map(PathBuf::from).collect()
    }

    /// Keeps only sensible values from the window.
    pub fn sanitized(mut self) -> Self {
        if !["system", "light", "dark"].contains(&self.theme.as_str()) {
            self.theme = "system".into();
        }
        self.exclusions.retain(|e| !e.trim().is_empty());
        self.exclusions.dedup();
        self
    }
}
