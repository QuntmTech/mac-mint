//! The user's known folders. Injected everywhere so tests run on temporary folders, never on
//! a real profile.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownFolders {
    /// %USERPROFILE%, e.g. C:\Users\Ada
    pub home: PathBuf,
    /// %LOCALAPPDATA%
    pub local_app_data: PathBuf,
    /// %APPDATA% (Roaming)
    pub roaming_app_data: PathBuf,
    /// %TEMP% for this user
    pub temp: PathBuf,
    pub downloads: PathBuf,
    /// Where MacMint keeps its own settings, history and journal.
    pub app_data: PathBuf,
}

impl KnownFolders {
    /// All folders under one root, laid out like a Windows profile. Used by tests.
    pub fn under(root: &Path) -> Self {
        let local = root.join("AppData/Local");
        Self {
            home: root.to_path_buf(),
            roaming_app_data: root.join("AppData/Roaming"),
            temp: local.join("Temp"),
            downloads: root.join("Downloads"),
            app_data: local.join("MacMint"),
            local_app_data: local,
        }
    }

    /// The current user's folders from the environment (Windows), or a profile-shaped layout
    /// under $HOME elsewhere so the app can be developed on other systems.
    pub fn current() -> Self {
        let env = |k: &str| std::env::var_os(k).map(PathBuf::from);
        #[cfg(windows)]
        {
            let home = env("USERPROFILE").unwrap_or_else(|| PathBuf::from(r"C:\Users\Default"));
            let local = env("LOCALAPPDATA").unwrap_or_else(|| home.join(r"AppData\Local"));
            Self {
                roaming_app_data: env("APPDATA").unwrap_or_else(|| home.join(r"AppData\Roaming")),
                temp: env("TEMP").unwrap_or_else(|| local.join("Temp")),
                downloads: home.join("Downloads"),
                app_data: local.join("MacMint"),
                local_app_data: local,
                home,
            }
        }
        #[cfg(not(windows))]
        {
            Self::under(&env("HOME").unwrap_or_else(|| PathBuf::from("/tmp")))
        }
    }

    /// Folders that hold the person's own documents. Never cleanup targets as a whole, and
    /// nothing inside them except reviewed files the person picked.
    pub fn personal_folders(&self) -> Vec<PathBuf> {
        ["Documents", "Desktop", "Pictures", "Music", "Videos", "OneDrive", "Favorites", "Contacts", "Saved Games"]
            .iter()
            .map(|n| self.home.join(n))
            .collect()
    }
}
