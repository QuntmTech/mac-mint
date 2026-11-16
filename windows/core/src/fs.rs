//! File-system helpers: measuring, comparison keys and the checks every move depends on.
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

/// Windows paths compare case-insensitively; normalize separators and case for comparison.
pub fn comparison_key(path: &Path) -> String {
    let mut out = String::new();
    for component in path.components() {
        match component {
            Component::Prefix(p) => out.push_str(&p.as_os_str().to_string_lossy()),
            Component::RootDir => out.push('/'),
            Component::CurDir => {}
            Component::ParentDir => out.push_str("../"),
            Component::Normal(s) => {
                out.push_str(&s.to_string_lossy());
                out.push('/');
            }
        }
    }
    let trimmed = if out.len() > 1 { out.trim_end_matches('/').to_string() } else { out };
    trimmed.replace('\\', "/").to_lowercase()
}

/// True when `path` is `root` or inside it (case-insensitive, component-aware).
pub fn is_inside_or_equal(path: &Path, root: &Path) -> bool {
    let p = comparison_key(path);
    let r = comparison_key(root);
    p == r || p.starts_with(&(r.trim_end_matches('/').to_string() + "/"))
}

/// Strictly inside (not equal).
pub fn is_strictly_inside(path: &Path, root: &Path) -> bool {
    is_inside_or_equal(path, root) && comparison_key(path) != comparison_key(root)
}

/// A symlink, junction or other reparse point. These are never followed or moved: on Windows a
/// junction inside a cache can point anywhere, including the user's documents.
pub fn is_link(path: &Path) -> bool {
    let Ok(meta) = std::fs::symlink_metadata(path) else { return false };
    if meta.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        if meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return true;
        }
    }
    false
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Measurement {
    pub bytes: u64,
    pub files: u64,
    /// Entries that couldn't be read (permission, in use).
    pub unreadable: u64,
}

/// Size on disk of a file or folder, never following links, skipping excluded paths.
pub fn measure(path: &Path, excluded: &[PathBuf]) -> Measurement {
    let mut m = Measurement::default();
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        m.unreadable += 1;
        return m;
    };
    if meta.is_file() {
        m.bytes = meta.len();
        m.files = 1;
        return m;
    }
    let walker = WalkDir::new(path).follow_links(false).into_iter().filter_entry(|e| {
        !excluded.iter().any(|x| is_inside_or_equal(e.path(), x)) && (e.depth() == 0 || !is_link(e.path()))
    });
    for entry in walker {
        match entry {
            Ok(e) if e.file_type().is_file() => match e.metadata() {
                Ok(md) => {
                    m.bytes = m.bytes.saturating_add(md.len());
                    m.files += 1;
                }
                Err(_) => m.unreadable += 1,
            },
            Ok(_) => {}
            Err(_) => m.unreadable += 1,
        }
    }
    m
}

/// Seconds since the epoch of the last modification.
pub fn modified_secs(path: &Path) -> Option<u64> {
    std::fs::symlink_metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
}

/// A cheap identity for "is this still the same item": creation time + size class + kind.
/// Windows has file IDs, but std doesn't expose them portably; creation time catches a folder
/// being deleted and recreated between review and move.
pub fn identity(path: &Path) -> Option<String> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    let created = meta
        .created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    Some(format!("{}:{}", if meta.is_dir() { "d" } else { "f" }, created))
}

pub fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Human-readable size, decimal units like Windows Explorer's newer builds and macOS.
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    if bytes < 1000 {
        return format!("{bytes} bytes");
    }
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if value >= 100.0 { format!("{value:.0} {}", UNITS[unit]) } else { format!("{value:.1} {}", UNITS[unit]) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inside_is_case_insensitive_and_component_aware() {
        assert!(is_inside_or_equal(Path::new("/Users/A/Temp/x"), Path::new("/users/a/temp")));
        assert!(!is_inside_or_equal(Path::new("/users/a/temp-old"), Path::new("/users/a/temp")));
        assert!(is_strictly_inside(Path::new("/a/b/c"), Path::new("/a/b")));
        assert!(!is_strictly_inside(Path::new("/a/b"), Path::new("/a/b")));
    }

    #[test]
    fn measures_files_without_following_links() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("sub")).unwrap();
        std::fs::write(dir.path().join("sub/a.bin"), vec![0u8; 3000]).unwrap();
        std::fs::write(dir.path().join("b.bin"), vec![0u8; 1000]).unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("big.bin"), vec![0u8; 50_000]).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(outside.path(), dir.path().join("link")).unwrap();
        let m = measure(dir.path(), &[]);
        assert_eq!(m.bytes, 4000, "a linked folder elsewhere is never counted");
        assert_eq!(measure(dir.path(), &[dir.path().join("sub")]).bytes, 1000);
    }

    #[test]
    fn formats_sizes() {
        assert_eq!(format_bytes(999), "999 bytes");
        assert_eq!(format_bytes(4_620_000_000), "4.6 GB");
        assert_eq!(format_bytes(123_000_000), "123 MB");
    }
}
