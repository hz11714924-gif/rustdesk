//! Optional, local-user screen previews. This module never opens a remote session.

use serde::{Deserialize, Serialize};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
#[cfg(windows)]
use std::{thread, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};

const DEFAULT_INTERVAL: u64 = 1;
const MAX_CA_PEM_BYTES: usize = 16 * 1024;
#[cfg(windows)]
const MAX_JPEG_BYTES: usize = 262_144;

#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct PreviewConfig {
    enabled: bool,
    base_url: String,
    ca_pem: String,
    upload_token: String,
    name: String,
    interval_seconds: u64,
}

impl Default for PreviewConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: String::new(),
            ca_pem: String::new(),
            upload_token: String::new(),
            name: String::new(),
            interval_seconds: DEFAULT_INTERVAL,
        }
    }
}

impl PreviewConfig {
    fn parse(json: &str) -> Result<Self, String> {
        let mut config: Self = serde_json::from_str(json)
            .map_err(|_| "Invalid preview configuration".to_owned())?;
        if !(1..=86_400).contains(&config.interval_seconds) {
            return Err("Preview interval must be between 1 and 86400 seconds".to_owned());
        }
        if config.name.chars().count() > 128 || config.name.chars().any(char::is_control) {
            return Err("Invalid preview device name".to_owned());
        }
        if config.ca_pem.len() > MAX_CA_PEM_BYTES {
            return Err("Preview CA certificate exceeds the 16 KiB limit".to_owned());
        }
        if !config.ca_pem.is_empty() {
            reqwest::Certificate::from_pem(config.ca_pem.as_bytes())
                .map_err(|_| "Invalid preview CA certificate".to_owned())?;
        }
        config.base_url = config.base_url.trim().trim_end_matches('/').to_owned();
        if !config.enabled {
            return Ok(config);
        }
        let parsed = url::Url::parse(&config.base_url)
            .map_err(|_| "Invalid preview service address".to_owned())?;
        if parsed.scheme() != "https" || parsed.host_str().is_none()
            || !parsed.username().is_empty() || parsed.password().is_some()
            || parsed.query().is_some() || parsed.fragment().is_some()
        {
            return Err("Preview service requires an HTTPS address without credentials or query".to_owned());
        }
        if config.upload_token.is_empty() || config.upload_token.len() > 4096
            || config.upload_token.trim() != config.upload_token
            || reqwest::header::HeaderValue::from_str(&format!("Bearer {}", config.upload_token)).is_err()
        {
            return Err("Invalid preview upload token".to_owned());
        }
        Ok(config)
    }
}

#[derive(Clone, Serialize)]
struct PreviewStatus {
    enabled: bool,
    state: &'static str,
    last_success_at: Option<u64>,
    last_error: Option<String>,
    device_id: String,
}

impl Default for PreviewStatus {
    fn default() -> Self {
        Self {
            enabled: false,
            state: if cfg!(windows) { "disabled" } else { "unsupported" },
            last_success_at: None,
            last_error: None,
            device_id: String::new(),
        }
    }
}

struct Inner {
    config: PreviewConfig,
    status: PreviewStatus,
    generation: u64,
    #[cfg(windows)]
    worker_started: bool,
    #[cfg(windows)]
    next_due: Instant,
}

impl Default for Inner {
    fn default() -> Self {
        Self {
            config: PreviewConfig::default(),
            status: PreviewStatus::default(),
            generation: 0,
            #[cfg(windows)]
            worker_started: false,
            #[cfg(windows)]
            next_due: Instant::now(),
        }
    }
}

#[derive(Default)]
struct Runtime {
    inner: Mutex<Inner>,
    wake: Condvar,
}

static RUNTIME: OnceLock<Arc<Runtime>> = OnceLock::new();

fn runtime() -> &'static Arc<Runtime> {
    RUNTIME.get_or_init(|| Arc::new(Runtime::default()))
}

/// The caller owns persistence and must only enable this in the interactive app.
pub fn configure(config_json: &str) -> Result<(), String> {
    let config = PreviewConfig::parse(config_json)?;
    let runtime = runtime();
    let mut inner = runtime.inner.lock().unwrap();
    if config.enabled && !cfg!(windows) {
        inner.status.state = "unsupported";
        inner.status.last_error = Some("Local previews are supported only on Windows".to_owned());
        return Err("Local previews are supported only on Windows".to_owned());
    }
    inner.generation = inner.generation.wrapping_add(1);
    inner.status.enabled = config.enabled;
    inner.status.state = if !cfg!(windows) { "unsupported" }
        else if config.enabled { "waiting" } else { "disabled" };
    inner.status.last_error = None;
    inner.config = config;
    #[cfg(windows)]
    {
        inner.next_due = Instant::now();
        if inner.config.enabled && !inner.worker_started {
            let worker_runtime = Arc::clone(runtime);
            let _worker = thread::Builder::new().name("local-screen-preview".to_owned())
                .spawn(move || worker(worker_runtime))
                .map_err(|_| {
                    inner.config.enabled = false;
                    inner.status.enabled = false;
                    inner.status.state = "error";
                    inner.status.last_error = Some("Unable to start preview worker".to_owned());
                    "Unable to start preview worker".to_owned()
                })?;
            inner.worker_started = true;
        }
    }
    runtime.wake.notify_all();
    Ok(())
}

pub fn stop() {
    let runtime = runtime();
    let mut inner = runtime.inner.lock().unwrap();
    inner.generation = inner.generation.wrapping_add(1);
    inner.config.enabled = false;
    inner.config.upload_token.clear();
    inner.status.enabled = false;
    inner.status.state = if cfg!(windows) { "disabled" } else { "unsupported" };
    inner.status.last_error = None;
    runtime.wake.notify_all();
}

pub fn status() -> String {
    let inner = runtime().inner.lock().unwrap();
    serde_json::to_string(&inner.status).unwrap_or_else(|_| {
        "{\"enabled\":false,\"state\":\"error\",\"last_success_at\":null,\"last_error\":\"Unable to serialize status\",\"device_id\":\"\"}".to_owned()
    })
}

#[cfg(any(windows, test))]
fn percent_encode(value: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut result = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            result.push(byte as char);
        } else {
            result.push('%');
            result.push(HEX[(byte >> 4) as usize] as char);
            result.push(HEX[(byte & 15) as usize] as char);
        }
    }
    result
}

#[cfg(windows)]
fn worker(runtime: Arc<Runtime>) {
    loop {
        let (config, generation) = {
            let mut inner = runtime.inner.lock().unwrap();
            loop {
                if !inner.config.enabled {
                    inner = runtime.wake.wait(inner).unwrap();
                } else if Instant::now() < inner.next_due {
                    let delay = inner.next_due.saturating_duration_since(Instant::now());
                    inner = runtime.wake.wait_timeout(inner, delay).unwrap().0;
                } else {
                    inner.status.state = "capturing";
                    break (inner.config.clone(), inner.generation);
                }
            }
        };
        let result = capture_and_upload(&runtime, generation, &config);
        let mut inner = runtime.inner.lock().unwrap();
        if inner.generation == generation && inner.config.enabled {
            match result {
                Ok(()) => {
                    inner.status.state = "ok";
                    inner.status.last_success_at = SystemTime::now().duration_since(UNIX_EPOCH)
                        .ok().map(|value| value.as_secs());
                    inner.status.last_error = None;
                }
                Err(error) => {
                    inner.status.state = "error";
                    inner.status.last_error = Some(error);
                }
            }
            inner.next_due = Instant::now() + Duration::from_secs(config.interval_seconds);
        }
    }
}

#[cfg(windows)]
fn capture_and_upload(
    runtime: &Runtime,
    generation: u64,
    config: &PreviewConfig,
) -> Result<(), String> {
    let id = hbb_common::config::Config::get_id();
    {
        let mut inner = runtime.inner.lock().unwrap();
        if inner.generation != generation || !inner.config.enabled {
            return Ok(());
        }
        if inner.status.device_id != id {
            inner.status.last_success_at = None;
            inner.status.device_id = id.clone();
        }
    }
    if id.trim().is_empty() {
        return Err("RustDesk device ID is not available".to_owned());
    }
    let mut builder = reqwest::blocking::Client::builder()
        .use_rustls_tls()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(15))
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none());
    if !config.ca_pem.is_empty() {
        let ca = reqwest::Certificate::from_pem(config.ca_pem.as_bytes())
            .map_err(|_| "Invalid preview CA certificate".to_owned())?;
        builder = builder.add_root_certificate(ca);
    }
    let uploader = builder.build()
        .map_err(|_| "Unable to initialize HTTPS uploader".to_owned())?;
    {
        let inner = runtime.inner.lock().unwrap();
        if inner.generation != generation || !inner.config.enabled {
            return Ok(());
        }
    }
    let jpeg = windows_capture::capture()?;
    if jpeg.len() > MAX_JPEG_BYTES {
        return Err("Preview exceeds the 256 KiB upload limit".to_owned());
    }
    {
        let mut inner = runtime.inner.lock().unwrap();
        if inner.generation != generation || !inner.config.enabled {
            return Ok(());
        }
        inner.status.state = "uploading";
    }
    let name = if config.name.is_empty() { &id } else { &config.name };
    let response = uploader.put(format!("{}/api/previews/{}", config.base_url, percent_encode(&id)))
        .header(reqwest::header::CONTENT_TYPE, "image/jpeg")
        .bearer_auth(&config.upload_token)
        .header("X-Device-Name", percent_encode(name))
        .header("X-Preview-Interval", config.interval_seconds.to_string())
        .body(jpeg).send().map_err(|_| "Preview upload failed".to_owned())?;
    if !response.status().is_success() {
        return Err(format!("Preview upload rejected (HTTP {})", response.status().as_u16()));
    }
    Ok(())
}

#[cfg(windows)]
mod windows_capture {
    use std::{mem::{size_of, zeroed}, ptr, slice};
    use winapi::{
        ctypes::c_void,
        shared::windef::{HBITMAP, HDC, HDESK, HGDIOBJ},
        um::{
            processthreadsapi::{GetCurrentProcessId, GetCurrentThreadId, ProcessIdToSessionId},
            wingdi::{
                CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GdiFlush,
                SelectObject, SetBrushOrgEx, SetStretchBltMode, StretchBlt, BITMAPINFO,
                BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS, HALFTONE, HGDI_ERROR, SRCCOPY,
            },
            winuser::{
                CloseDesktop, GetDC, GetSystemMetrics, GetThreadDesktop, GetUserObjectInformationW,
                OpenInputDesktop, ReleaseDC, DESKTOP_READOBJECTS, SM_CXSCREEN, SM_CYSCREEN, UOI_NAME,
            },
        },
    };

    struct ScreenDc(HDC);
    impl Drop for ScreenDc {
        fn drop(&mut self) { unsafe { ReleaseDC(ptr::null_mut(), self.0); } }
    }
    struct MemoryDc(HDC);
    impl Drop for MemoryDc {
        fn drop(&mut self) { unsafe { DeleteDC(self.0); } }
    }
    struct Bitmap(HBITMAP);
    impl Drop for Bitmap {
        fn drop(&mut self) { unsafe { DeleteObject(self.0 as HGDIOBJ); } }
    }
    struct SelectedBitmap(HDC, HGDIOBJ);
    impl Drop for SelectedBitmap {
        fn drop(&mut self) { unsafe { SelectObject(self.0, self.1); } }
    }
    struct InputDesktop(HDESK);
    impl Drop for InputDesktop {
        fn drop(&mut self) { unsafe { CloseDesktop(self.0); } }
    }

    unsafe fn desktop_name(desktop: HDESK) -> Result<String, String> {
        let mut name = [0u16; 256];
        let mut needed = 0;
        if desktop.is_null() || GetUserObjectInformationW(
            desktop as _, UOI_NAME as _, name.as_mut_ptr() as _,
            (name.len() * size_of::<u16>()) as _, &mut needed,
        ) == 0 {
            return Err("Interactive desktop is unavailable".to_owned());
        }
        let end = name.iter().position(|value| *value == 0).unwrap_or(name.len());
        String::from_utf16(&name[..end]).map_err(|_| "Invalid desktop name".to_owned())
    }

    pub fn capture() -> Result<Vec<u8>, String> {
        unsafe {
            let mut session_id = 0;
            if ProcessIdToSessionId(GetCurrentProcessId(), &mut session_id) == 0 || session_id == 0 {
                return Err("Preview requires an interactive user session".to_owned());
            }
            let input = InputDesktop(OpenInputDesktop(0, 0, DESKTOP_READOBJECTS));
            if input.0.is_null() {
                return Err("Screen is locked or the interactive desktop is unavailable".to_owned());
            }
            let input_name = desktop_name(input.0)?;
            let current_name = desktop_name(GetThreadDesktop(GetCurrentThreadId()))?;
            if !input_name.eq_ignore_ascii_case("Default") || input_name != current_name {
                return Err("Preview is unavailable on a locked or secure desktop".to_owned());
            }
            let source_width = GetSystemMetrics(SM_CXSCREEN);
            let source_height = GetSystemMetrics(SM_CYSCREEN);
            if source_width <= 0 || source_height <= 0 {
                return Err("Primary screen is unavailable".to_owned());
            }
            let scale = (320.0 / source_width as f64).min(180.0 / source_height as f64).min(1.0);
            let width = ((source_width as f64 * scale).floor() as i32).max(1);
            let height = ((source_height as f64 * scale).floor() as i32).max(1);
            let screen = ScreenDc(GetDC(ptr::null_mut()));
            if screen.0.is_null() {
                return Err("Unable to read the current screen".to_owned());
            }
            let memory = MemoryDc(CreateCompatibleDC(screen.0));
            if memory.0.is_null() {
                return Err("Unable to allocate preview display context".to_owned());
            }
            let mut info: BITMAPINFO = zeroed();
            info.bmiHeader = BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as _, biWidth: width, biHeight: -height,
                biPlanes: 1, biBitCount: 32, biCompression: BI_RGB,
                ..zeroed()
            };
            let mut bits: *mut c_void = ptr::null_mut();
            let bitmap = Bitmap(CreateDIBSection(screen.0, &info, DIB_RGB_COLORS, &mut bits, ptr::null_mut(), 0));
            if bitmap.0.is_null() || bits.is_null() {
                return Err("Unable to allocate preview pixels".to_owned());
            }
            let old = SelectObject(memory.0, bitmap.0 as HGDIOBJ);
            if old.is_null() || old == HGDI_ERROR {
                return Err("Unable to select preview bitmap".to_owned());
            }
            let _selected = SelectedBitmap(memory.0, old);
            if SetStretchBltMode(memory.0, HALFTONE) == 0
                || SetBrushOrgEx(memory.0, 0, 0, ptr::null_mut()) == 0
                || StretchBlt(memory.0, 0, 0, width, height, screen.0, 0, 0,
                    source_width, source_height, SRCCOPY | CAPTUREBLT) == 0
                || GdiFlush() == 0
            {
                return Err("Unable to capture the current screen".to_owned());
            }
            let bgra = slice::from_raw_parts(bits as *const u8, (width * height * 4) as usize);
            let mut rgb = Vec::with_capacity((width * height * 3) as usize);
            for pixel in bgra.chunks_exact(4) {
                rgb.extend_from_slice(&[pixel[2], pixel[1], pixel[0]]);
            }
            let mut jpeg = Vec::new();
            image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 35)
                .encode(&rgb, width as _, height as _, image::ColorType::Rgb8)
                .map_err(|_| "Unable to encode preview image".to_owned())?;
            Ok(jpeg)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{percent_encode, PreviewConfig};

    #[test]
    fn previews_are_disabled_without_credentials_by_default() {
        let config = PreviewConfig::parse("{}").unwrap();
        assert!(!config.enabled);
        assert_eq!(config.interval_seconds, 1);
    }

    #[test]
    fn preview_interval_is_bounded() {
        assert!(PreviewConfig::parse(r#"{"interval_seconds":0}"#).is_err());
        assert!(PreviewConfig::parse(r#"{"interval_seconds":86401}"#).is_err());
        assert!(PreviewConfig::parse(r#"{"interval_seconds":1}"#).is_ok());
    }

    #[test]
    fn enabled_previews_require_https_and_a_valid_token() {
        assert!(PreviewConfig::parse(r#"{"enabled":true,"base_url":"http://example.com","upload_token":"x"}"#).is_err());
        assert!(PreviewConfig::parse(r#"{"enabled":true,"base_url":"https://example.com"}"#).is_err());
        assert!(PreviewConfig::parse(r#"{"enabled":true,"base_url":"https://example.com/path","upload_token":"x"}"#).is_ok());
        assert_eq!(percent_encode("电脑 A"), "%E7%94%B5%E8%84%91%20A");
    }

    #[test]
    fn invalid_preview_ca_pem_is_rejected() {
        assert!(PreviewConfig::parse(r#"{"ca_pem":"not a PEM certificate"}"#).is_err());
        let oversized = serde_json::json!({"ca_pem": "x".repeat(super::MAX_CA_PEM_BYTES + 1)});
        assert!(PreviewConfig::parse(&oversized.to_string()).is_err());
    }
}
