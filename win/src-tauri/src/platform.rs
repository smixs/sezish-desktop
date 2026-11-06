use crate::error::AppError;
use async_trait::async_trait;
use sez_core::{Clock, Inserter, SezError};
use std::path::Path;
use std::time::{Duration, Instant};

pub struct SystemClock {
    epoch: Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        Self {
            epoch: Instant::now(),
        }
    }
}

impl Clock for SystemClock {
    fn now(&self) -> Duration {
        self.epoch.elapsed()
    }
}

#[cfg(windows)]
pub fn system_locale() -> String {
    use windows::Win32::Globalization::GetUserDefaultLocaleName;

    let mut locale = [0_u16; 85];
    let length = unsafe { GetUserDefaultLocaleName(&mut locale) };
    if length <= 1 {
        return String::new();
    }
    String::from_utf16_lossy(&locale[..usize::try_from(length - 1).unwrap_or(0)])
}

#[cfg(not(windows))]
pub fn system_locale() -> String {
    std::env::var("LANG").unwrap_or_default()
}

#[cfg(windows)]
pub struct PlatformInserter(sez_inject::WindowsInserter);

#[cfg(windows)]
impl PlatformInserter {
    pub fn new() -> Self {
        Self(sez_inject::WindowsInserter::new())
    }
}

#[cfg(windows)]
#[async_trait]
impl Inserter for PlatformInserter {
    async fn insert(&self, text: &str) -> Result<(), SezError> {
        self.0.insert(text).await
    }
}

#[cfg(not(windows))]
pub struct PlatformInserter;

#[cfg(not(windows))]
impl PlatformInserter {
    pub fn new() -> Self {
        Self
    }
}

#[cfg(not(windows))]
#[async_trait]
impl Inserter for PlatformInserter {
    async fn insert(&self, _text: &str) -> Result<(), SezError> {
        Err(SezError::Other(
            "text insertion is available only on Windows".to_owned(),
        ))
    }
}

#[cfg(windows)]
pub fn copy_text(text: &str) -> Result<(), AppError> {
    use sez_inject::{Clipboard, WinClipboard};

    let clipboard = WinClipboard;
    clipboard.set_text(text);
    if clipboard.get_text().as_deref() == Some(text) {
        Ok(())
    } else {
        Err(AppError::platform(
            "could not write to the Windows clipboard",
        ))
    }
}

#[cfg(not(windows))]
pub fn copy_text(_text: &str) -> Result<(), AppError> {
    Err(AppError::platform(
        "clipboard integration is available only on Windows",
    ))
}

#[cfg(windows)]
pub fn open_history_folder(path: &Path) -> Result<(), AppError> {
    std::process::Command::new("explorer.exe")
        .arg(path)
        .spawn()
        .map(|_| ())
        .map_err(|error| AppError::platform(error.to_string()))
}

/// The default browser, through the shell like the history folder.
#[cfg(windows)]
pub fn open_url(url: &str) -> Result<(), AppError> {
    std::process::Command::new("explorer.exe")
        .arg(url)
        .spawn()
        .map(|_| ())
        .map_err(|error| AppError::platform(error.to_string()))
}

#[cfg(not(windows))]
pub fn open_url(_url: &str) -> Result<(), AppError> {
    Ok(())
}

#[cfg(not(windows))]
pub fn open_history_folder(_path: &Path) -> Result<(), AppError> {
    Ok(())
}

#[cfg(windows)]
pub fn autostart_enabled() -> Result<bool, AppError> {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_READ};
    use winreg::RegKey;

    let current_user = RegKey::predef(HKEY_CURRENT_USER);
    let run = match current_user
        .open_subkey_with_flags(r"Software\Microsoft\Windows\CurrentVersion\Run", KEY_READ)
    {
        Ok(run) => run,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(AppError::platform(error.to_string())),
    };
    Ok(run.get_value::<String, _>("sezish").is_ok())
}

#[cfg(not(windows))]
pub fn autostart_enabled() -> Result<bool, AppError> {
    Ok(false)
}

#[cfg(windows)]
pub fn set_autostart(enabled: bool) -> Result<(), AppError> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    let current_user = RegKey::predef(HKEY_CURRENT_USER);
    let (run, _) = current_user
        .create_subkey(r"Software\Microsoft\Windows\CurrentVersion\Run")
        .map_err(|error| AppError::platform(error.to_string()))?;
    if enabled {
        let executable =
            std::env::current_exe().map_err(|error| AppError::platform(error.to_string()))?;
        let command = format!("\"{}\"", executable.display());
        run.set_value("sezish", &command)
            .map_err(|error| AppError::platform(error.to_string()))
    } else {
        match run.delete_value("sezish") {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(AppError::platform(error.to_string())),
        }
    }
}

#[cfg(not(windows))]
pub fn set_autostart(_enabled: bool) -> Result<(), AppError> {
    Ok(())
}

/// Blocking error box for startup failures. Only used before the tray exists,
/// when there is no other way to tell the user anything.
#[cfg(windows)]
pub fn show_fatal_dialog(message: &str) {
    use std::os::windows::ffi::OsStrExt;
    use windows::core::PCWSTR;
    use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};

    let wide = |text: &str| -> Vec<u16> {
        std::ffi::OsStr::new(text)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    };
    let text = wide(message);
    let caption = wide("sezish");
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(text.as_ptr()),
            PCWSTR(caption.as_ptr()),
            MB_OK | MB_ICONERROR,
        );
    }
}

#[cfg(not(windows))]
pub fn show_fatal_dialog(message: &str) {
    eprintln!("{message}");
}

/// Centre of the foreground window in physical pixels: the HUD shows on the
/// monitor the user is working on, not always on the primary one.
#[cfg(windows)]
pub fn foreground_window_center() -> Option<(f64, f64)> {
    use windows::Win32::Foundation::RECT;
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowRect};
    unsafe {
        let window = GetForegroundWindow();
        if window.is_invalid() {
            return None;
        }
        let mut rect = RECT::default();
        GetWindowRect(window, &mut rect).ok()?;
        Some((
            f64::from(rect.left + rect.right) / 2.0,
            f64::from(rect.top + rect.bottom) / 2.0,
        ))
    }
}

#[cfg(not(windows))]
pub fn foreground_window_center() -> Option<(f64, f64)> {
    None
}

/// The three microphone switches under Privacy & security, each `Allow`, `Deny`
/// or absent (never touched, which is on). Any `Deny` keeps sezish deaf.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn microphone_from(
    device: Option<&str>,
    user: Option<&str>,
    desktop_apps: Option<&str>,
) -> crate::onboarding::Microphone {
    use crate::onboarding::Microphone;
    let values = [device, user, desktop_apps];
    if values.contains(&Some("Deny")) {
        Microphone::Denied
    } else if values
        .iter()
        .all(|value| matches!(value, None | Some("Allow")))
    {
        Microphone::Granted
    } else {
        Microphone::Undetermined
    }
}

#[cfg(windows)]
pub fn microphone_access() -> crate::onboarding::Microphone {
    use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ};
    use winreg::RegKey;

    const STORE: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    let read = |root, path: &str| -> Option<String> {
        RegKey::predef(root)
            .open_subkey_with_flags(path, KEY_READ)
            .ok()?
            .get_value::<String, _>("Value")
            .ok()
    };
    let device = read(HKEY_LOCAL_MACHINE, STORE);
    let user = read(HKEY_CURRENT_USER, STORE);
    let desktop = read(HKEY_CURRENT_USER, &format!(r"{STORE}\NonPackaged"));
    microphone_from(device.as_deref(), user.as_deref(), desktop.as_deref())
}

#[cfg(not(windows))]
pub fn microphone_access() -> crate::onboarding::Microphone {
    crate::onboarding::Microphone::Granted
}

#[cfg(test)]
mod tests {
    use super::microphone_from;
    use crate::onboarding::Microphone;

    /// Privacy & security → Microphone: the device switch, «Microphone access» for
    /// this user and «Let desktop apps access your microphone» each turn it off on
    /// their own. Windows writes the values only once a switch was touched, and the
    /// untouched default is on.
    #[test]
    fn the_microphone_is_off_when_any_of_the_three_switches_is() {
        assert_eq!(microphone_from(None, None, None), Microphone::Granted);
        assert_eq!(
            microphone_from(Some("Allow"), Some("Allow"), Some("Allow")),
            Microphone::Granted
        );
        assert_eq!(
            microphone_from(Some("Deny"), None, None),
            Microphone::Denied
        );
        assert_eq!(
            microphone_from(None, Some("Deny"), None),
            Microphone::Denied
        );
        assert_eq!(
            microphone_from(Some("Allow"), Some("Allow"), Some("Deny")),
            Microphone::Denied
        );
        assert_eq!(
            microphone_from(Some("Prompt"), None, None),
            Microphone::Undetermined
        );
    }
}
