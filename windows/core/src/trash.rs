//! Moving to the Recycle Bin and putting things back. Never deletes outright.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrashReceipt {
    pub original_path: PathBuf,
    pub bytes: u64,
    /// When it was moved, seconds since the epoch.
    pub trashed_at: u64,
    /// The Recycle Bin's own id for the item, when it could be found right after the move.
    /// Without it, restoring falls back to matching name, folder and time.
    pub trash_id: Option<String>,
}

pub trait TrashService: Send + Sync {
    fn trash(&self, path: &Path, bytes: u64) -> Result<TrashReceipt, String>;
    /// Put an item back where it was. Refuses when something now exists at that place.
    fn restore(&self, receipt: &TrashReceipt) -> Result<(), String>;
    /// Whether the item is still in the Recycle Bin (None when that can't be told).
    fn still_in_trash(&self, receipt: &TrashReceipt) -> Option<bool>;
}

/// The system Recycle Bin (Windows), or the freedesktop Trash when developing on Linux.
pub struct RecycleBin;

#[cfg(any(windows, all(unix, not(target_os = "macos"))))]
mod platform {
    use super::*;

    fn matches(item: &trash::TrashItem, receipt: &TrashReceipt) -> bool {
        let original = item.original_parent.join(&item.name);
        crate::fs::comparison_key(&original) == crate::fs::comparison_key(&receipt.original_path)
            && (item.time_deleted - receipt.trashed_at as i64).abs() <= 120
    }

    pub fn find(receipt: &TrashReceipt) -> Result<Option<trash::TrashItem>, String> {
        let items = trash::os_limited::list().map_err(|e| e.to_string())?;
        if let Some(id) = &receipt.trash_id {
            if let Some(item) = items.iter().find(|i| i.id.to_string_lossy() == *id) {
                return Ok(Some(item.clone()));
            }
        }
        Ok(items.into_iter().filter(|i| matches(i, receipt)).max_by_key(|i| i.time_deleted))
    }

    pub fn id_after_move(path: &Path, trashed_at: u64) -> Option<String> {
        let probe = TrashReceipt { original_path: path.to_path_buf(), bytes: 0, trashed_at, trash_id: None };
        find(&probe).ok().flatten().map(|i| i.id.to_string_lossy().to_string())
    }

    pub fn restore(receipt: &TrashReceipt) -> Result<(), String> {
        let item = find(receipt)?.ok_or("It's no longer in the Recycle Bin.")?;
        trash::os_limited::restore_all([item]).map_err(|e| match e {
            trash::Error::RestoreCollision { .. } => "Something else is already at its original place.".to_string(),
            other => other.to_string(),
        })
    }
}

impl TrashService for RecycleBin {
    fn trash(&self, path: &Path, bytes: u64) -> Result<TrashReceipt, String> {
        let trashed_at = crate::fs::now_secs();
        trash::delete(path).map_err(|e| e.to_string())?;
        #[cfg(any(windows, all(unix, not(target_os = "macos"))))]
        let trash_id = platform::id_after_move(path, trashed_at);
        #[cfg(not(any(windows, all(unix, not(target_os = "macos")))))]
        let trash_id = None;
        Ok(TrashReceipt { original_path: path.to_path_buf(), bytes, trashed_at, trash_id })
    }

    fn restore(&self, receipt: &TrashReceipt) -> Result<(), String> {
        if receipt.original_path.exists() {
            return Err("Something else is already at its original place.".into());
        }
        #[cfg(any(windows, all(unix, not(target_os = "macos"))))]
        return platform::restore(receipt);
        #[cfg(not(any(windows, all(unix, not(target_os = "macos")))))]
        return Err("Restore it from the Trash yourself.".into());
    }

    fn still_in_trash(&self, receipt: &TrashReceipt) -> Option<bool> {
        #[cfg(any(windows, all(unix, not(target_os = "macos"))))]
        return platform::find(receipt).ok().map(|i| i.is_some());
        #[cfg(not(any(windows, all(unix, not(target_os = "macos")))))]
        return None;
    }
}

/// A folder standing in for the Recycle Bin, for tests.
pub struct FolderTrash {
    pub folder: PathBuf,
}

impl TrashService for FolderTrash {
    fn trash(&self, path: &Path, bytes: u64) -> Result<TrashReceipt, String> {
        std::fs::create_dir_all(&self.folder).map_err(|e| e.to_string())?;
        let id = format!("{}-{}", crate::fs::now_secs(), path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
        let dest = self.folder.join(&id);
        std::fs::rename(path, &dest).map_err(|e| e.to_string())?;
        Ok(TrashReceipt { original_path: path.to_path_buf(), bytes, trashed_at: crate::fs::now_secs(), trash_id: Some(id) })
    }

    fn restore(&self, receipt: &TrashReceipt) -> Result<(), String> {
        if receipt.original_path.exists() {
            return Err("Something else is already at its original place.".into());
        }
        let id = receipt.trash_id.as_ref().ok_or("No Recycle Bin id.")?;
        std::fs::rename(self.folder.join(id), &receipt.original_path).map_err(|e| e.to_string())
    }

    fn still_in_trash(&self, receipt: &TrashReceipt) -> Option<bool> {
        receipt.trash_id.as_ref().map(|id| self.folder.join(id).exists())
    }
}
