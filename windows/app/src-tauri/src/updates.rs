//! Developer-channel updates: a small JSON feed on the repository's dev-feed release names the
//! newest Windows build, its installer and SHA-256. The installer is downloaded only from this
//! repository's releases, checked against that digest, then started; MacMint closes for it.
use serde::Serialize;
use serde_json::Value;
use sha2::Digest;

pub const FEED_URL: &str = "https://github.com/QuntmTech/mac-mint/releases/download/dev-feed/windows-dev.json";
const DOWNLOAD_PREFIX: &str = "https://github.com/QuntmTech/mac-mint/releases/download/";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub current: String,
    pub build: u64,
    pub latest: Option<String>,
    pub latest_build: Option<u64>,
    pub available: bool,
    pub notes: Option<String>,
    pub published_at: Option<String>,
    pub message: Option<String>,
    #[serde(skip)]
    pub url: Option<String>,
    #[serde(skip)]
    pub sha256: Option<String>,
}

pub fn current_build() -> u64 {
    option_env!("MACMINT_BUILD").and_then(|b| b.parse().ok()).unwrap_or(0)
}

pub async fn check(version: &str) -> UpdateInfo {
    let mut info = UpdateInfo { current: version.into(), build: current_build(), latest: None, latest_build: None, available: false, notes: None, published_at: None, message: None, url: None, sha256: None };
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(20)).user_agent("MacMint-Windows").build().expect("client");
    let resp = match client.get(FEED_URL).send().await {
        Ok(r) => r,
        Err(_) => {
            info.message = Some("Couldn't reach the update feed. Check your connection.".into());
            return info;
        }
    };
    if resp.status().as_u16() == 404 {
        info.message = Some("No Windows build has been published yet.".into());
        return info;
    }
    let Ok(feed) = resp.json::<Value>().await else {
        info.message = Some("The update feed couldn't be read.".into());
        return info;
    };
    let build = feed["build"].as_u64();
    let url = feed["url"].as_str().filter(|u| u.starts_with(DOWNLOAD_PREFIX)).map(String::from);
    let sha = feed["sha256"].as_str().filter(|s| s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit())).map(|s| s.to_lowercase());
    info.latest = feed["version"].as_str().map(String::from);
    info.latest_build = build;
    info.notes = feed["notes"].as_str().map(String::from);
    info.published_at = feed["publishedAt"].as_str().map(String::from);
    info.available = matches!((build, &url, &sha), (Some(b), Some(_), Some(_)) if b > info.build);
    info.message = Some(if info.available { format!("Build {} is ready to install.", build.unwrap_or(0)) } else { "You have the newest build.".into() });
    info.url = url;
    info.sha256 = sha;
    info
}

/// Downloads and verifies the installer; returns where it was saved.
pub async fn download(info: &UpdateInfo) -> Result<std::path::PathBuf, String> {
    let (Some(url), Some(expected)) = (&info.url, &info.sha256) else { return Err("No update to install.".into()) };
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(600)).user_agent("MacMint-Windows").build().map_err(|e| e.to_string())?;
    let bytes = client.get(url).send().await.and_then(|r| r.error_for_status()).map_err(|_| "The download didn't finish. Try again.".to_string())?.bytes().await.map_err(|_| "The download didn't finish. Try again.".to_string())?;
    let actual = hex::encode(sha2::Sha256::digest(&bytes));
    if &actual != expected {
        return Err("The download didn't match its checksum, so it wasn't opened.".into());
    }
    let dir = std::env::temp_dir().join(format!("MacMint-update-{}", info.latest_build.unwrap_or(0)));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join("MacMint-Setup.exe");
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    Ok(path)
}
