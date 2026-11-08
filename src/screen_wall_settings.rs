use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::PathBuf,
    sync::Mutex,
};

use serde::{Deserialize, Serialize};
use winapi::{
    shared::minwindef::HLOCAL,
    um::{
        winbase::LocalFree,
        dpapi::{CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN},
        wincrypt::DATA_BLOB,
    },
};

const SETTINGS_KEY: &str = "screen-wall-config";
const STATUS_KEY: &str = "screen-wall-status";
const MAX_SETTINGS_BYTES: usize = 64 * 1024;
const MAX_PRIVATE_SETTINGS_BYTES: usize = 32 * 1024;
const MAGIC: &[u8] = b"RustDeskScreenWall\x01";

lazy_static::lazy_static! {
    static ref SETTINGS_LOCK: Mutex<()> = Mutex::new(());
    static ref SETTINGS_ERROR: Mutex<String> = Mutex::new(String::new());
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(default)]
struct Settings {
    api_url: String,
    ca_pem: String,
    viewer_token: String,
    upload_enabled: bool,
    upload_token: String,
    device_name: String,
    interval_seconds: u64,
    credentials_managed: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            api_url: "https://103.236.79.91:21181".to_owned(),
            ca_pem: include_str!("../res/screen_wall/preview-ca.pem").to_owned(),
            viewer_token: String::new(),
            upload_enabled: false,
            upload_token: String::new(),
            device_name: String::new(),
            interval_seconds: 1,
            credentials_managed: false,
        }
    }
}

impl Settings {
    fn validate(&self) -> Result<(), String> {
        if !(1..=86_400).contains(&self.interval_seconds) {
            return Err("Refresh interval must be between 1 and 86400 seconds".into());
        }
        if self.api_url.len() > 2048 || self.device_name.chars().count() > 80 {
            return Err("Preview settings exceed the supported length".into());
        }
        if self.device_name.chars().any(char::is_control) {
            return Err("Invalid preview device name".into());
        }
        if self.ca_pem.len() > 16 * 1024
            || (!self.ca_pem.is_empty() && reqwest::Certificate::from_pem(self.ca_pem.as_bytes()).is_err())
        {
            return Err("Invalid preview CA certificate".into());
        }
        for token in [&self.viewer_token, &self.upload_token] {
            if token.len() > 4096 || token.chars().any(|c| c.is_control())
                || token.trim() != token
                || (!token.is_empty() && reqwest::header::HeaderValue::from_str(
                    &format!("Bearer {}", token)).is_err())
            {
                return Err("Invalid preview token".into());
            }
        }
        if !self.api_url.is_empty() {
            let url = url::Url::parse(&self.api_url)
                .map_err(|_| "Invalid preview service URL".to_owned())?;
            if url.scheme() != "https"
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err("Use an HTTPS preview service URL without embedded credentials".into());
            }
        }
        if self.upload_enabled && (self.api_url.is_empty() || self.upload_token.is_empty()) {
            return Err("A preview service URL and device token are required for uploading".into());
        }
        Ok(())
    }
}

fn settings_path() -> Result<PathBuf, String> {
    let root = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| "The current user's application data directory is unavailable".to_owned())?;
    Ok(root.join("RustDesk").join("screen-wall").join("settings.bin"))
}

fn protect(bytes: &[u8], decrypt: bool) -> Result<Vec<u8>, String> {
    if bytes.len() > MAX_SETTINGS_BYTES {
        return Err("Preview settings exceed the size limit".into());
    }
    let mut input = DATA_BLOB {
        cbData: bytes.len() as u32,
        pbData: bytes.as_ptr() as *mut u8,
    };
    let mut output = DATA_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    let ok = unsafe {
        if decrypt {
            CryptUnprotectData(
                &mut input, std::ptr::null_mut(), std::ptr::null_mut(),
                std::ptr::null_mut(), std::ptr::null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN, &mut output,
            )
        } else {
            CryptProtectData(
                &mut input, std::ptr::null(), std::ptr::null_mut(),
                std::ptr::null_mut(), std::ptr::null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN, &mut output,
            )
        }
    };
    if ok == 0 {
        return Err("Windows could not protect or open the preview settings".into());
    }
    let result = if output.pbData.is_null() || output.cbData as usize > MAX_SETTINGS_BYTES {
        Err("Invalid protected preview settings".into())
    } else {
        Ok(unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec())
    };
    if !output.pbData.is_null() {
        unsafe { LocalFree(output.pbData as HLOCAL); }
    }
    result
}

fn read_private_settings(reader: impl Read) -> Result<Settings, String> {
    let mut bytes = Vec::new();
    reader.take((MAX_PRIVATE_SETTINGS_BYTES + 1) as u64).read_to_end(&mut bytes)
        .map_err(|_| "Unable to read private preview settings".to_owned())?;
    if bytes.len() > MAX_PRIVATE_SETTINGS_BYTES {
        return Err("Private preview settings exceed the 32 KiB limit".into());
    }
    let mut settings: Settings = serde_json::from_slice(&bytes)
        .map_err(|_| "Invalid private preview settings".to_owned())?;
    settings.validate()?;
    if settings.api_url.is_empty() || settings.viewer_token.is_empty()
        || settings.upload_token.is_empty() || !settings.upload_enabled
    {
        return Err("Private preview settings require viewing and enabled upload credentials".into());
    }
    settings.credentials_managed = true;
    Ok(settings)
}

fn load_private_settings() -> Result<Option<Settings>, String> {
    let executable = std::env::current_exe()
        .map_err(|_| "Unable to locate private preview settings".to_owned())?;
    let directory = executable.parent()
        .ok_or_else(|| "Unable to locate private preview settings".to_owned())?;
    match fs::File::open(directory.join("data").join("screen-wall-private.json")) {
        Ok(file) => read_private_settings(file).map(Some),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("Unable to read private preview settings".into()),
    }
}

fn select_settings(saved: Option<Settings>, private: Option<Settings>) -> Settings {
    match saved {
        Some(saved) if !saved.upload_token.is_empty() => saved,
        Some(saved) => match private {
            Some(mut private) => {
                if !saved.device_name.is_empty() {
                    private.device_name = saved.device_name;
                }
                private
            }
            None => saved,
        },
        None => private.unwrap_or_default(),
    }
}

fn load_saved_settings() -> Result<Option<Settings>, String> {
    let path = settings_path()?;
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("Unable to read preview settings".into()),
    };
    let mut bytes = Vec::new();
    file.take((MAX_SETTINGS_BYTES + 1) as u64).read_to_end(&mut bytes)
        .map_err(|_| "Unable to read preview settings".to_owned())?;
    if bytes.len() > MAX_SETTINGS_BYTES || !bytes.starts_with(MAGIC) {
        return Err("Invalid protected preview settings".into());
    }
    let plain = protect(&bytes[MAGIC.len()..], true)?;
    let settings: Settings = serde_json::from_slice(&plain)
        .map_err(|_| "Invalid preview settings".to_owned())?;
    settings.validate()?;
    Ok(Some(settings))
}

fn load() -> Result<Settings, String> {
    let saved = load_saved_settings()?;
    if let Some(settings) = saved.as_ref() {
        if !settings.upload_token.is_empty() {
            return Ok(select_settings(saved, None));
        }
    }
    Ok(select_settings(saved, load_private_settings()?))
}

fn save(settings: &Settings) -> Result<(), String> {
    let path = settings_path()?;
    let parent = path.parent().ok_or_else(|| "Invalid preview settings path".to_owned())?;
    fs::create_dir_all(parent).map_err(|_| "Unable to create preview settings directory".to_owned())?;
    let plain = serde_json::to_vec(settings).map_err(|_| "Invalid preview settings".to_owned())?;
    let encrypted = protect(&plain, false)?;
    let temporary = parent.join(format!("settings-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> std::io::Result<()> {
        let mut file = OpenOptions::new().write(true).create_new(true).open(&temporary)?;
        file.write_all(MAGIC)?;
        file.write_all(&encrypted)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, &path)
    })();
    if result.is_err() {
        let _cleanup = fs::remove_file(&temporary);
        return Err("Unable to save protected preview settings".into());
    }
    Ok(())
}

fn set_error(error: Option<String>) {
    *SETTINGS_ERROR.lock().unwrap() = error.unwrap_or_default();
}

pub fn get(key: &str) -> Option<String> {
    if key == STATUS_KEY {
        let mut status: serde_json::Value = serde_json::from_str(&crate::low_frequency_preview::status())
            .unwrap_or_else(|_| serde_json::json!({"enabled": false, "state": "error"}));
        status["settings_error"] = serde_json::Value::String(SETTINGS_ERROR.lock().unwrap().clone());
        return Some(status.to_string());
    }
    if key != SETTINGS_KEY {
        return None;
    }
    let _lock = SETTINGS_LOCK.lock().unwrap();
    let settings = match load() {
        Ok(settings) => settings,
        Err(error) => {
            set_error(Some(error));
            Settings::default()
        }
    };
    Some(serde_json::to_string(&settings).unwrap_or_default())
}

pub fn set(key: &str, value: &str) -> bool {
    if key != SETTINGS_KEY {
        return false;
    }
    let _lock = SETTINGS_LOCK.lock().unwrap();
    let result = (|| -> Result<(), String> {
        if value.len() > MAX_SETTINGS_BYTES / 2 {
            return Err("Preview settings exceed the size limit".into());
        }
        let settings: Settings = serde_json::from_str(value)
            .map_err(|_| "Invalid preview settings".to_owned())?;
        settings.validate()?;
        save(&settings)?;
        crate::low_frequency_preview::configure(&serde_json::json!({
            "enabled": settings.upload_enabled,
            "base_url": settings.api_url,
            "ca_pem": settings.ca_pem,
            "upload_token": settings.upload_token,
            "name": settings.device_name,
            "interval_seconds": settings.interval_seconds,
        }).to_string())
    })();
    set_error(result.err());
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_defaults_do_not_capture_or_upload() {
        let settings = Settings::default();
        assert!(!settings.upload_enabled);
        assert_eq!(settings.interval_seconds, 1);
        assert!(settings.validate().is_ok());
    }

    #[test]
    fn uploading_requires_an_https_service_and_separate_device_token() {
        let mut settings = Settings { upload_enabled: true, ..Settings::default() };
        assert!(settings.validate().is_err());
        settings.api_url = "http://example.com".into();
        settings.upload_token = "device-token".into();
        assert!(settings.validate().is_err());
        settings.api_url = "https://example.com".into();
        assert!(settings.validate().is_ok());
    }

    fn private_settings() -> Settings {
        read_private_settings(br#"{"viewer_token":"test-viewer","upload_token":"test-uploader","upload_enabled":true}"#.as_slice()).unwrap()
    }

    #[test]
    fn private_package_starts_uploading_and_migrates_empty_credentials() {
        let first = select_settings(None, Some(private_settings()));
        assert!(first.upload_enabled && first.credentials_managed);
        assert!(first.device_name.is_empty());
        assert_eq!(first.interval_seconds, 1);
        let previous = Settings { device_name: "Office".into(), ..Settings::default() };
        let migrated = select_settings(Some(previous), Some(private_settings()));
        assert!(migrated.upload_enabled && migrated.credentials_managed);
        assert_eq!(migrated.device_name, "Office");
        assert_eq!(migrated.upload_token, "test-uploader");
    }

    #[test]
    fn saved_credentials_and_explicitly_disabled_upload_keep_priority() {
        let mut saved = private_settings();
        saved.upload_enabled = false;
        saved.upload_token = "existing-device-token".into();
        saved.interval_seconds = 300;
        let restored = select_settings(Some(saved), Some(private_settings()));
        assert!(!restored.upload_enabled);
        assert!(restored.credentials_managed);
        assert_eq!(restored.upload_token, "existing-device-token");
        assert_eq!(restored.interval_seconds, 300);
        assert!(!select_settings(None, None).upload_enabled);
    }

    #[test]
    fn private_settings_are_bounded_and_allow_one_second_uploads() {
        let mut settings = private_settings();
        settings.interval_seconds = 1;
        assert!(settings.validate().is_ok());
        settings.interval_seconds = 0;
        assert!(settings.validate().is_err());
        assert!(read_private_settings(br#"{"upload_enabled":true}"#.as_slice()).is_err());
        assert!(read_private_settings(&vec![b' '; MAX_PRIVATE_SETTINGS_BYTES + 1][..]).is_err());
    }
}
