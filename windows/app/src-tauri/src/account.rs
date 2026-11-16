//! The MacMint account: sign-in, this PC's activation and the plan that unlocks moving files.
//! Same server and rules as the Mac app. The session token lives in Windows Credential Manager;
//! the server-signed offline pass (Ed25519) lives in the data folder and is verified on use.
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;

pub const BASE_URL: &str = "https://macmint.cloudpod.pro";
const KEYRING_SERVICE: &str = "MacMint";
const KEYRING_USER: &str = "session";
/// Production signing keys, as in the Mac app (docs/ENTITLEMENTS.md).
const PUBLIC_KEYS: &[(&str, &str)] = &[("mm-ent-2026-10", "g9rOE6LVZtQmiwfDzIXhnEP7SEzGp49TZDw3iDs9rCw=")];
const CLOCK_SKEW: u64 = 300;
const MAX_WINDOW: u64 = 60 * 86_400;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Snapshot {
    pub user: User,
    pub entitlement: Entitlement,
    #[serde(default)]
    pub device: Option<Value>,
    #[serde(default)]
    pub entitlement_assertion: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct User {
    pub id: String,
    pub email: String,
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Entitlement {
    #[serde(default)]
    pub plan: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub active: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountStatus {
    pub signed_in: bool,
    pub email: Option<String>,
    pub name: Option<String>,
    pub plan: Option<String>,
    pub unlocked: bool,
    pub offline: bool,
    pub device_name: String,
    pub message: Option<String>,
    pub ai_available: bool,
}

#[derive(Debug, Clone)]
pub struct ApiError {
    pub status: u16,
    pub code: String,
    pub message: String,
}

impl ApiError {
    fn network() -> Self {
        Self { status: 0, code: "network".into(), message: "MacMint couldn't reach the account service. Check your connection.".into() }
    }
}

#[derive(Default)]
pub struct Account {
    pub token: Option<String>,
    pub snapshot: Option<Snapshot>,
    pub offline_unlocked: Option<(String, String)>, // (email, plan) from a verified offline pass
    pub message: Option<String>,
    pub ai_enabled_remote: bool,
    pub ai_reachable: bool,
}

pub struct Device {
    pub id: String,
    pub name: String,
    pub model: String,
    pub os_version: String,
    pub app_version: String,
}

pub fn device(app_version: &str) -> Device {
    use sha2::Digest;
    let seed = machine_guid().unwrap_or_else(|| macmint_core::system::computer_name());
    let id = hex::encode(sha2::Sha256::digest(format!("macmint-windows:{seed}").as_bytes()))[..32].to_string();
    Device { id, name: macmint_core::system::computer_name(), model: model().unwrap_or_else(|| "Windows PC".into()), os_version: macmint_core::system::os_version(), app_version: app_version.into() }
}

#[cfg(windows)]
fn machine_guid() -> Option<String> {
    use winreg::enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY};
    winreg::RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags("SOFTWARE\\Microsoft\\Cryptography", KEY_READ | KEY_WOW64_64KEY).ok()?.get_value("MachineGuid").ok()
}
#[cfg(not(windows))]
fn machine_guid() -> Option<String> {
    std::fs::read_to_string("/etc/machine-id").ok().map(|s| s.trim().to_string())
}

#[cfg(windows)]
fn model() -> Option<String> {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    let k = winreg::RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey("HARDWARE\\DESCRIPTION\\System\\BIOS").ok()?;
    let maker: String = k.get_value("SystemManufacturer").unwrap_or_default();
    let product: String = k.get_value("SystemProductName").ok()?;
    Some(format!("{} {}", maker.trim(), product.trim()).trim().to_string())
}
#[cfg(not(windows))]
fn model() -> Option<String> {
    None
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().timeout(std::time::Duration::from_secs(25)).user_agent("MacMint-Windows").build().expect("http client")
}

async fn send(method: reqwest::Method, path: &str, token: Option<&str>, body: Option<Value>, timeout: u64) -> Result<Value, ApiError> {
    let mut req = client().request(method, format!("{BASE_URL}{path}")).header("Accept", "application/json").timeout(std::time::Duration::from_secs(timeout));
    if let Some(t) = token {
        req = req.header("Authorization", t);
    }
    if let Some(b) = body {
        req = req.json(&b);
    }
    let resp = req.send().await.map_err(|_| ApiError::network())?;
    let status = resp.status().as_u16();
    let data: Value = resp.json().await.unwrap_or(Value::Null);
    if (200..300).contains(&status) {
        return Ok(data);
    }
    let field = data.get("data").and_then(|d| d.as_object()).and_then(|m| m.iter().find_map(|(k, v)| v.get("message").and_then(|m| m.as_str()).map(|m| format!("{}: {m}", capitalize(k)))));
    let fallback = match status {
        400 => "Please check what you entered and try again.".to_string(),
        401 => "Your session has expired. Please sign in again.".to_string(),
        429 => "Too many attempts. Wait a minute and try again.".to_string(),
        500.. => "MacMint is having trouble right now. Please try again shortly.".to_string(),
        _ => format!("Something went wrong ({status})."),
    };
    let message = field.or_else(|| data.get("message").and_then(|m| m.as_str()).filter(|m| !m.is_empty()).map(String::from)).unwrap_or(fallback);
    let code = data.get("error").and_then(|e| e.as_str()).map(String::from).unwrap_or_else(|| if status == 401 { "unauthorized".into() } else { format!("http_{status}") });
    Err(ApiError { status, code, message })
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

fn snapshot(v: Value) -> Result<Snapshot, ApiError> {
    serde_json::from_value(v).map_err(|_| ApiError { status: 200, code: "bad_response".into(), message: "MacMint sent an unexpected response.".into() })
}

pub fn saved_token() -> Option<String> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER).ok()?.get_password().ok()
}

fn save_token(token: &str) {
    if let Ok(e) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER) {
        let _ = e.set_password(token);
    }
}

fn clear_token() {
    if let Ok(e) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER) {
        let _ = e.delete_credential();
    }
}

fn pass_path(dir: &std::path::Path) -> PathBuf {
    dir.join("offline-pass.json")
}

/// Checks a server-signed offline pass for this PC: signature, key, user, device, window, clock.
pub fn verify_pass(compact: &str, device_id: &str, user_id: Option<&str>, now: u64, high_water: u64) -> Result<(String, Value), String> {
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let (payload_b64, sig_b64) = compact.split_once('.').ok_or("malformed")?;
    if compact.len() > 4096 {
        return Err("too long".into());
    }
    let payload = b64.decode(payload_b64.trim_end_matches('=')).map_err(|_| "payload")?;
    let sig = b64.decode(sig_b64.trim_end_matches('=')).map_err(|_| "signature")?;
    let claims: Value = serde_json::from_slice(&payload).map_err(|_| "claims")?;
    let kid = claims["kid"].as_str().ok_or("kid")?;
    let key_b64 = PUBLIC_KEYS.iter().find(|(k, _)| *k == kid).map(|(_, v)| *v).ok_or("unknown key")?;
    let key_bytes: [u8; 32] = base64::engine::general_purpose::STANDARD.decode(key_b64).map_err(|_| "key")?.try_into().map_err(|_| "key length")?;
    let sig: [u8; 64] = sig.try_into().map_err(|_| "signature length")?;
    let key = ed25519_dalek::VerifyingKey::from_bytes(&key_bytes).map_err(|_| "key")?;
    key.verify_strict(&payload, &ed25519_dalek::Signature::from_bytes(&sig)).map_err(|_| "signature doesn't match")?;
    if claims["v"].as_i64() != Some(1) || claims["active"].as_bool() != Some(true) {
        return Err("inactive".into());
    }
    if claims["device_id"].as_str() != Some(device_id) {
        return Err("another device".into());
    }
    if let Some(u) = user_id {
        if claims["user_id"].as_str() != Some(u) {
            return Err("another user".into());
        }
    }
    let issued = claims["issued_at"].as_u64().ok_or("issued_at")?;
    let until = claims["offline_until"].as_u64().ok_or("offline_until")?.min(issued + MAX_WINDOW);
    let seen = high_water.max(issued);
    if now + CLOCK_SKEW < seen {
        return Err("clock moved back".into());
    }
    if let Some(exp) = claims["expires_at"].as_u64() {
        if now >= exp {
            return Err("expired".into());
        }
    }
    if now >= until {
        return Err("offline window ended".into());
    }
    Ok((claims["plan"].as_str().unwrap_or("pro").to_string(), claims))
}

fn now() -> u64 {
    macmint_core::fs::now_secs()
}

impl Account {
    pub fn unlocked(&self) -> bool {
        match &self.snapshot {
            Some(s) => s.entitlement.active && s.device.is_some(),
            None => self.offline_unlocked.is_some(),
        }
    }

    pub fn status(&self, device_name: &str, ai_consented: bool) -> AccountStatus {
        let signed_in = self.token.is_some() || self.offline_unlocked.is_some();
        let (email, name, plan) = match (&self.snapshot, &self.offline_unlocked) {
            (Some(s), _) => (Some(s.user.email.clone()), s.user.name.clone().filter(|n| !n.is_empty()), s.entitlement.active.then(|| plan_label(&s.entitlement.plan))),
            (None, Some((email, plan))) => (Some(email.clone()), None, Some(plan_label(plan))),
            _ => (None, None, None),
        };
        AccountStatus {
            signed_in,
            email,
            name,
            plan,
            unlocked: self.unlocked(),
            offline: self.snapshot.is_none() && self.offline_unlocked.is_some(),
            device_name: device_name.into(),
            message: self.message.clone(),
            ai_available: self.unlocked() && self.ai_enabled_remote && self.ai_reachable && ai_consented,
        }
    }

    fn adopt(&mut self, snap: Snapshot, dir: &std::path::Path, device_id: &str) {
        // Keep a verified offline pass; drop stale evidence when the server sends none.
        match snap.entitlement_assertion.as_deref() {
            Some(pass) if verify_pass(pass, device_id, Some(&snap.user.id), now(), 0).is_ok() => {
                let _ = macmint_core::executor::write_durably(&pass_path(dir), json!({ "pass": pass, "email": snap.user.email, "highWater": now() }).to_string().as_bytes());
            }
            _ => {
                let _ = std::fs::remove_file(pass_path(dir));
            }
        }
        self.offline_unlocked = None;
        self.message = if !snap.entitlement.active {
            Some("Signed in. This account doesn't have an active MacMint plan yet, so scanning works but moving files is locked.".into())
        } else if snap.device.is_none() {
            Some("This PC isn't activated yet.".into())
        } else {
            None
        };
        self.snapshot = Some(snap);
    }

    /// Launch: use the saved session; fall back to a valid offline pass only for network trouble.
    pub async fn start(&mut self, dir: &std::path::Path, device: &Device) {
        self.token = saved_token();
        let Some(token) = self.token.clone() else { return };
        match send(reqwest::Method::GET, &format!("/api/macmint/me?device_id={}", device.id), Some(&token), None, 20).await {
            Ok(v) => match snapshot(v) {
                Ok(snap) => {
                    let needs_device = snap.device.is_none() && snap.entitlement.active;
                    self.adopt(snap, dir, &device.id);
                    if needs_device {
                        let _ = self.activate(dir, device, false).await;
                    }
                }
                Err(e) => self.message = Some(e.message),
            },
            Err(e) if e.status == 401 => {
                self.sign_out_locally(dir);
                self.message = Some("Your session ended. Please sign in again.".into());
            }
            Err(e) => {
                self.message = Some(e.message);
                self.try_offline(dir, device);
            }
        }
    }

    fn try_offline(&mut self, dir: &std::path::Path, device: &Device) {
        let Some(saved) = std::fs::read(pass_path(dir)).ok().and_then(|d| serde_json::from_slice::<Value>(&d).ok()) else { return };
        let high = saved["highWater"].as_u64().unwrap_or(0);
        if let (Some(pass), Some(email)) = (saved["pass"].as_str(), saved["email"].as_str()) {
            if let Ok((plan, _)) = verify_pass(pass, &device.id, None, now(), high) {
                self.offline_unlocked = Some((email.into(), plan));
                self.message = Some("Offline: using this PC's saved pass until the account service is reachable.".into());
                let _ = macmint_core::executor::write_durably(&pass_path(dir), json!({ "pass": pass, "email": email, "highWater": high.max(now()) }).to_string().as_bytes());
            }
        }
    }

    async fn activate(&mut self, dir: &std::path::Path, device: &Device, reactivate: bool) -> Result<(), ApiError> {
        let token = self.token.clone().ok_or_else(ApiError::network)?;
        let body = json!({ "device_id": device.id, "reactivate": reactivate, "name": device.name, "model": device.model, "os_version": device.os_version, "app_version": device.app_version });
        match send(reqwest::Method::POST, "/api/macmint/devices/activate", Some(&token), Some(body), 20).await {
            Ok(v) => {
                let snap = snapshot(v)?;
                self.adopt(snap, dir, &device.id);
                Ok(())
            }
            Err(e) => {
                self.message = Some(match e.status {
                    409 if e.code == "device_limit" => "Your plan's device limit is reached. Remove a device at macmint.co/account, then try again.".into(),
                    409 => "This PC was removed from your account. Choose Activate this PC to add it back.".into(),
                    402 => "This account doesn't have an active MacMint plan yet, so scanning works but moving files is locked.".into(),
                    _ => e.message.clone(),
                });
                Err(e)
            }
        }
    }

    pub async fn sign_in(&mut self, dir: &std::path::Path, device: &Device, email: &str, password: &str) -> Result<(), String> {
        let v = send(reqwest::Method::POST, "/api/collections/users/auth-with-password", None, Some(json!({ "identity": email.trim(), "password": password })), 20).await.map_err(|e| if e.status == 400 { "That email and password don't match an account.".to_string() } else { e.message })?;
        let token = v["token"].as_str().ok_or("MacMint sent an unexpected response.")?.to_string();
        save_token(&token);
        self.token = Some(token.clone());
        self.message = None;
        let me = send(reqwest::Method::GET, &format!("/api/macmint/me?device_id={}", device.id), Some(&token), None, 20).await.map_err(|e| e.message)?;
        let snap = snapshot(me).map_err(|e| e.message)?;
        let active = snap.entitlement.active;
        self.adopt(snap, dir, &device.id);
        if active {
            let _ = self.activate(dir, device, true).await;
        }
        Ok(())
    }

    pub async fn refresh(&mut self, dir: &std::path::Path, device: &Device) {
        let had = self.snapshot.as_ref().map(|s| s.device.is_none()).unwrap_or(false);
        self.start(dir, device).await;
        if had && self.snapshot.as_ref().map(|s| s.entitlement.active && s.device.is_none()).unwrap_or(false) {
            let _ = self.activate(dir, device, true).await;
        }
    }

    pub fn sign_out_locally(&mut self, dir: &std::path::Path) {
        clear_token();
        let _ = std::fs::remove_file(pass_path(dir));
        *self = Account::default();
    }

    pub async fn refresh_ai_status(&mut self) {
        let url = format!("{BASE_URL}/api/collections/app_config/records?filter=key%3D%27ai%27");
        match client().get(url).timeout(std::time::Duration::from_secs(15)).send().await {
            Ok(r) if r.status().is_success() => {
                let v: Value = r.json().await.unwrap_or(Value::Null);
                self.ai_reachable = true;
                self.ai_enabled_remote = v["items"][0]["value"]["enabled"].as_bool() == Some(true) && v["items"][0]["value"]["features"]["ask"].as_bool() != Some(false);
            }
            _ => {
                self.ai_reachable = false;
                self.ai_enabled_remote = false;
            }
        }
    }
}

fn plan_label(plan: &str) -> String {
    match plan {
        "" | "pro" => "Pro".into(),
        other => capitalize(other),
    }
}

/// Sends a question to the MacMint assistant. Only the typed question, earlier turns and two
/// numbers (drive size and free space) are sent; never file names or paths.
pub async fn ask(token: &str, question: &str, history: &[(String, String)], total_gb: f64, free_gb: f64) -> Result<String, String> {
    let turns: Vec<Value> = history.iter().rev().take(6).rev().map(|(r, t)| json!({ "role": r, "text": t })).collect();
    let q: String = format!("[Windows PC] {}", question.trim()).chars().take(600).collect();
    let body = json!({
        "question": q,
        "history": turns,
        "context": { "disk": { "totalGB": total_gb, "freeGB": free_gb }, "recommendations": [], "biggestFolders": [], "developerGB": {}, "unusedApps": [], "downloadsGB": {}, "startupItems": [], "recentGrowth": [] }
    });
    let v = send(reqwest::Method::POST, "/api/macmint/ai/ask", Some(token), Some(body), 45).await.map_err(|e| e.message)?;
    v["answer"].as_str().map(String::from).ok_or_else(|| "The assistant sent an unexpected response.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_forged_and_foreign_passes() {
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let claims = json!({"active":true,"device_id":"d1","expires_at":null,"issued_at":1000,"kid":"mm-ent-2026-10","offline_until":2000,"plan":"pro","user_id":"u","v":1});
        let forged = format!("{}.{}", b64.encode(claims.to_string()), b64.encode([0u8; 64]));
        assert!(verify_pass(&forged, "d1", None, 1500, 0).is_err());
        assert!(verify_pass("nonsense", "d1", None, 1500, 0).is_err());
    }
}
