//! What may ever be moved to the Recycle Bin, decided again right before every move.
//! Allowlists per kind of item; everything else is refused.
use crate::fs::{comparison_key, is_inside_or_equal, is_link, is_strictly_inside};
use crate::model::CleanupCategory;
use crate::paths::KnownFolders;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct SafetyPolicy {
    folders: KnownFolders,
}

/// Folder names inside browser and app profiles that hold sign-ins and site data.
pub const PROFILE_DATA_NAMES: &[&str] = &[
    "Cookies", "Network", "Local Storage", "IndexedDB", "Session Storage", "Service Worker",
    "databases", "Login Data", "Web Data", "History", "Bookmarks", "Preferences", "Extensions",
    "Local Extension Settings", "Sync Data", "blob_storage", "File System", "User", "WebStorage",
];

/// Chromium/Electron cache folder names that only ever hold disposable cache data.
pub const CACHE_FOLDER_NAMES: &[&str] = &[
    "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
    "ShaderCache", "GrShaderCache", "CachedData", "CachedExtensionVSIXs", "cache2", "startupCache",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allowed,
    Refused(String),
}

impl Decision {
    pub fn allowed(&self) -> bool {
        matches!(self, Decision::Allowed)
    }
}

impl SafetyPolicy {
    pub fn new(folders: KnownFolders) -> Self {
        Self { folders }
    }

    pub fn folders(&self) -> &KnownFolders {
        &self.folders
    }

    /// Checks every target must pass, whatever it is.
    pub fn baseline(&self, path: &Path) -> Decision {
        let key = comparison_key(path);
        let system_roots = ["c:/windows", "c:/program files", "c:/program files (x86)", "c:/programdata", "c:/system volume information", "c:/$recycle.bin"];
        if system_roots.iter().any(|r| key == *r || key.starts_with(&format!("{r}/"))) {
            return Decision::Refused("Windows and installed programs are never touched.".into());
        }
        if !is_strictly_inside(path, &self.folders.home) {
            return Decision::Refused("Only items inside your user folder can be moved.".into());
        }
        if is_inside_or_equal(path, &self.folders.app_data) {
            return Decision::Refused("MacMint's own data is kept.".into());
        }
        if is_link(path) {
            return Decision::Refused("Links and junctions are never moved; they can point anywhere.".into());
        }
        if path.parent().map(|p| comparison_key(p) == comparison_key(&self.folders.home)).unwrap_or(false) {
            return Decision::Refused("Top-level folders in your user folder are never moved as a whole.".into());
        }
        Decision::Allowed
    }

    /// A scanned cleanup target: baseline plus the category's own allowlist.
    pub fn cleanup(&self, path: &Path, category: CleanupCategory) -> Decision {
        if let Decision::Refused(r) = self.baseline(path) {
            return Decision::Refused(r);
        }
        if self.inside_personal(path) {
            return Decision::Refused("Your documents, pictures and desktop are never cleanup targets.".into());
        }
        let f = &self.folders;
        let ok = match category {
            CleanupCategory::TempFiles => is_strictly_inside(path, &f.temp),
            CleanupCategory::AppCaches => self.is_app_cache(path),
            CleanupCategory::LogsAndReports => [
                f.local_app_data.join("CrashDumps"),
                f.local_app_data.join("Microsoft/Windows/WER"),
            ]
            .iter()
            .any(|r| is_strictly_inside(path, r)),
            CleanupCategory::DeveloperCaches => self.developer_cache_roots().iter().any(|r| is_strictly_inside(path, r)),
            CleanupCategory::Installers => {
                is_strictly_inside(path, &f.downloads) && is_installer_name(path)
            }
        };
        if ok { Decision::Allowed } else { Decision::Refused(format!("Outside the allowed places for {}.", category.title().to_lowercase())) }
    }

    /// A file the person picked themselves (large files, duplicates, downloads).
    pub fn reviewed_file(&self, path: &Path) -> Decision {
        if let Decision::Refused(r) = self.baseline(path) {
            return Decision::Refused(r);
        }
        let app_data_roots = [&self.folders.local_app_data, &self.folders.roaming_app_data];
        if app_data_roots.iter().any(|r| is_inside_or_equal(path, r)) {
            return Decision::Refused("App data is only removed through its own cleanup rules.".into());
        }
        Decision::Allowed
    }

    /// A project build folder (node_modules, target, .gradle…) next to its tool's marker file.
    pub fn developer_artifact(&self, path: &Path) -> Decision {
        if let Decision::Refused(r) = self.baseline(path) {
            return Decision::Refused(r);
        }
        if self.developer_cache_roots().iter().any(|r| is_strictly_inside(path, r)) {
            return Decision::Allowed;
        }
        if crate::developer::is_project_artifact(path) { Decision::Allowed } else { Decision::Refused("Not a recognized build folder next to its project file.".into()) }
    }

    /// Leftover app data in AppData, reviewed one by one.
    pub fn app_leftover(&self, path: &Path) -> Decision {
        if let Decision::Refused(r) = self.baseline(path) {
            return Decision::Refused(r);
        }
        let roots = [&self.folders.local_app_data, &self.folders.roaming_app_data];
        let inside = roots.iter().any(|r| path.parent().map(|p| comparison_key(p) == comparison_key(r)).unwrap_or(false));
        let protected = ["microsoft", "packages", "temp", "programs", "macmint", "google", "mozilla"];
        let name = path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
        if inside && !protected.contains(&name.as_str()) { Decision::Allowed } else { Decision::Refused("Only a single app's folder directly in AppData can be a leftover.".into()) }
    }

    fn inside_personal(&self, path: &Path) -> bool {
        self.folders.personal_folders().iter().any(|p| is_inside_or_equal(path, p))
    }

    /// A named cache folder inside a known app's data, never a profile, its parent, or
    /// anything inside sign-in and site data.
    fn is_app_cache(&self, path: &Path) -> bool {
        let roots = [&self.folders.local_app_data, &self.folders.roaming_app_data];
        if !roots.iter().any(|r| is_strictly_inside(path, r)) {
            return false;
        }
        let components: Vec<String> = path.components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
        if components.iter().any(|c| PROFILE_DATA_NAMES.iter().any(|n| n.eq_ignore_ascii_case(c))) {
            return false;
        }
        let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let parent = path.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        CACHE_FOLDER_NAMES.iter().any(|n| n.eq_ignore_ascii_case(&name))
            || parent.eq_ignore_ascii_case("CachedData")
            || parent.eq_ignore_ascii_case("cache2")
    }

    pub fn developer_cache_roots(&self) -> Vec<PathBuf> {
        let f = &self.folders;
        vec![
            f.local_app_data.join("npm-cache/_cacache"),
            f.local_app_data.join("pip/Cache"),
            f.local_app_data.join("Yarn/Cache"),
            f.local_app_data.join("pnpm/store"),
            f.local_app_data.join("NuGet/v3-cache"),
            f.local_app_data.join("go-build"),
            f.home.join(".gradle/caches"),
            f.home.join(".cargo/registry/cache"),
            f.local_app_data.join("Microsoft/VisualStudio/Packages/_Instances"),
        ]
    }
}

pub fn is_installer_name(path: &Path) -> bool {
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    ["exe", "msi", "msix", "msixbundle", "appx", "zip", "7z", "rar", "iso", "img"].contains(&ext.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy() -> (tempfile::TempDir, SafetyPolicy) {
        let dir = tempfile::tempdir().unwrap();
        let p = SafetyPolicy::new(KnownFolders::under(dir.path()));
        (dir, p)
    }

    #[test]
    fn refuses_windows_program_files_personal_and_top_level() {
        let (dir, p) = policy();
        assert!(!p.baseline(Path::new("C:/Windows/Temp/x")).allowed());
        assert!(!p.baseline(Path::new("C:/Program Files/App")).allowed());
        assert!(!p.baseline(dir.path()).allowed());
        assert!(!p.baseline(&dir.path().join("AppData")).allowed(), "a top-level folder of the profile");
        assert!(!p.cleanup(&dir.path().join("Documents/Temp/x"), CleanupCategory::TempFiles).allowed());
    }

    #[test]
    fn temp_children_are_allowed_but_not_temp_itself() {
        let (dir, p) = policy();
        let temp = dir.path().join("AppData/Local/Temp");
        assert!(p.cleanup(&temp.join("setup123"), CleanupCategory::TempFiles).allowed());
        assert!(!p.cleanup(&temp, CleanupCategory::TempFiles).allowed());
    }

    #[test]
    fn app_caches_never_reach_sign_ins_or_profiles() {
        let (dir, p) = policy();
        let chrome = dir.path().join("AppData/Local/Google/Chrome/User Data/Default");
        assert!(p.cleanup(&chrome.join("Cache"), CleanupCategory::AppCaches).allowed());
        assert!(p.cleanup(&chrome.join("Code Cache"), CleanupCategory::AppCaches).allowed());
        assert!(!p.cleanup(&chrome, CleanupCategory::AppCaches).allowed(), "never a whole profile");
        assert!(!p.cleanup(&chrome.join("Network/Cookies"), CleanupCategory::AppCaches).allowed());
        assert!(!p.cleanup(&chrome.join("IndexedDB/Cache"), CleanupCategory::AppCaches).allowed());
    }

    #[test]
    fn installers_only_in_downloads_and_only_installer_files() {
        let (dir, p) = policy();
        assert!(p.cleanup(&dir.path().join("Downloads/setup.exe"), CleanupCategory::Installers).allowed());
        assert!(!p.cleanup(&dir.path().join("Downloads/report.pdf"), CleanupCategory::Installers).allowed());
        assert!(!p.cleanup(&dir.path().join("Desktop/setup.exe"), CleanupCategory::Installers).allowed());
    }

    #[cfg(unix)]
    #[test]
    fn links_are_refused() {
        let (dir, p) = policy();
        let temp = dir.path().join("AppData/Local/Temp");
        std::fs::create_dir_all(&temp).unwrap();
        std::os::unix::fs::symlink(dir.path().join("Documents"), temp.join("docs")).unwrap();
        assert!(!p.cleanup(&temp.join("docs"), CleanupCategory::TempFiles).allowed());
    }
}
