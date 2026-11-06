use crate::typing::{
    batch_len, build_typing_events, choose_route, classify, InsertRoute, TypeEvent, TypeOutcome,
    TypeUnit, TypedKey,
};
use crate::{
    Clipboard, InsertionEngine, Key, KeyEvent, KeyState, PASTE_CHORD_EVENT_COUNT, RESTORE_DELAY,
};
use async_trait::async_trait;
use sez_core::{Clock, Inserter, SezError};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    KEYEVENTF_UNICODE, VIRTUAL_KEY, VK_CONTROL, VK_RETURN, VK_TAB, VK_V,
};

/// Real Win32 Unicode clipboard adapter.
pub struct WinClipboard;

impl Clipboard for WinClipboard {
    fn get_text(&self) -> Option<String> {
        let _clipboard = ClipboardGuard::open()?;
        let handle = unsafe { GetClipboardData(CF_UNICODETEXT.0 as u32).ok()? };
        let global = HGLOBAL(handle.0);
        let pointer = unsafe { GlobalLock(global) }.cast::<u16>();
        if pointer.is_null() {
            return None;
        }
        let _lock = GlobalLockGuard(global);

        let mut length = 0;
        unsafe {
            while *pointer.add(length) != 0 {
                length += 1;
            }
            String::from_utf16(std::slice::from_raw_parts(pointer, length)).ok()
        }
    }

    fn set_text(&self, text: &str) {
        let mut utf16: Vec<u16> = text.encode_utf16().collect();
        utf16.push(0);
        let byte_count = utf16.len() * std::mem::size_of::<u16>();

        let Ok(global) = (unsafe { GlobalAlloc(GMEM_MOVEABLE, byte_count) }) else {
            return;
        };
        let pointer = unsafe { GlobalLock(global) }.cast::<u16>();
        if pointer.is_null() {
            free_global(global);
            return;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(utf16.as_ptr(), pointer, utf16.len());
            let _ = GlobalUnlock(global);
        }

        let Some(_clipboard) = ClipboardGuard::open() else {
            free_global(global);
            return;
        };
        if unsafe { EmptyClipboard() }.is_err() {
            free_global(global);
            return;
        }
        if unsafe { SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(global.0))) }.is_err() {
            free_global(global);
            return;
        }
        set_markers();
    }
}

/// Stamps the open clipboard with the formats that keep it out of history.
fn set_markers() {
    use windows::Win32::System::DataExchange::RegisterClipboardFormatW;
    for marker in crate::guard::clipboard_markers() {
        let name: Vec<u16> = marker.format.encode_utf16().chain(Some(0)).collect();
        let format = unsafe { RegisterClipboardFormatW(windows::core::PCWSTR(name.as_ptr())) };
        if format == 0 {
            continue;
        }
        let bytes = marker
            .dword
            .map_or(0, |_| std::mem::size_of::<u32>())
            .max(1);
        let Ok(global) = (unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes) }) else {
            continue;
        };
        let pointer = unsafe { GlobalLock(global) }.cast::<u8>();
        if pointer.is_null() {
            free_global(global);
            continue;
        }
        unsafe {
            match marker.dword {
                Some(value) => std::ptr::copy_nonoverlapping(
                    value.to_le_bytes().as_ptr(),
                    pointer,
                    std::mem::size_of::<u32>(),
                ),
                None => *pointer = 0,
            }
            let _ = GlobalUnlock(global);
        }
        if unsafe { SetClipboardData(format, Some(HANDLE(global.0))) }.is_err() {
            free_global(global);
        }
    }
}

/// Integrity level of a process token: ours, or the foreground window's owner.
fn token_level(
    process: windows::Win32::Foundation::HANDLE,
) -> Option<crate::guard::IntegrityLevel> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::Security::{
        GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TokenIntegrityLevel,
        TOKEN_MANDATORY_LABEL, TOKEN_QUERY,
    };
    use windows::Win32::System::Threading::OpenProcessToken;
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token).ok()?;
        let mut buffer = [0u8; 128];
        let mut length = 0u32;
        let read = GetTokenInformation(
            token,
            TokenIntegrityLevel,
            Some(buffer.as_mut_ptr().cast()),
            buffer.len() as u32,
            &mut length,
        );
        let _ = CloseHandle(token);
        read.ok()?;
        let label = &*(buffer.as_ptr().cast::<TOKEN_MANDATORY_LABEL>());
        let sid = label.Label.Sid;
        let count = *GetSidSubAuthorityCount(sid);
        if count == 0 {
            return None;
        }
        let rid = *GetSidSubAuthority(sid, u32::from(count - 1));
        Some(crate::guard::IntegrityLevel::from_rid(rid))
    }
}

/// True when the window that has the caret belongs to a process above us
/// (run as administrator): our events would be dropped without an error.
pub fn foreground_blocks_input() -> bool {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        GetCurrentProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
    let Some(own) = token_level(unsafe { GetCurrentProcess() }) else {
        return false;
    };
    unsafe {
        let window = GetForegroundWindow();
        if window.is_invalid() {
            return false;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(window, Some(&mut pid));
        if pid == 0 {
            return false;
        }
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return false;
        };
        let target = token_level(process);
        let _ = CloseHandle(process);
        target.is_some_and(|target| crate::guard::input_blocked(own, target))
    }
}

struct ClipboardGuard;

impl ClipboardGuard {
    fn open() -> Option<Self> {
        unsafe { OpenClipboard(None) }.ok()?;
        Some(Self)
    }
}

impl Drop for ClipboardGuard {
    fn drop(&mut self) {
        let _ = unsafe { CloseClipboard() };
    }
}

struct GlobalLockGuard(HGLOBAL);

impl Drop for GlobalLockGuard {
    fn drop(&mut self) {
        let _ = unsafe { GlobalUnlock(self.0) };
    }
}

fn free_global(global: HGLOBAL) {
    let _ = unsafe { GlobalFree(Some(global)) };
}

struct MonotonicClock {
    epoch: Instant,
}

impl MonotonicClock {
    fn new() -> Self {
        Self {
            epoch: Instant::now(),
        }
    }
}

impl Clock for MonotonicClock {
    fn now(&self) -> Duration {
        self.epoch.elapsed()
    }
}

/// Real Windows implementation of the frozen insertion seam.
pub struct WindowsInserter {
    engine: InsertionEngine<WinClipboard, MonotonicClock>,
}

impl WindowsInserter {
    /// Creates a Win32 clipboard and SendInput-backed inserter.
    pub fn new() -> Self {
        Self {
            engine: InsertionEngine::new(
                std::sync::Arc::new(WinClipboard),
                std::sync::Arc::new(MonotonicClock::new()),
            ),
        }
    }
}

impl Default for WindowsInserter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Inserter for WindowsInserter {
    /// Empty text is inserted as nothing at all: no events, no clipboard write.
    async fn insert(&self, text: &str) -> Result<(), SezError> {
        if !text.is_empty() && foreground_blocks_input() {
            // Typing or pasting into it would vanish: hand the text over instead.
            WinClipboard.set_text(text);
            return Err(SezError::Other(
                "the focused window runs as administrator - the dictation is on your clipboard"
                    .to_owned(),
            ));
        }
        if choose_route(text) == InsertRoute::Type {
            let typed = text.to_owned();
            let outcome = tokio::task::spawn_blocking(move || send_typed_text(&typed))
                .await
                .map_err(|error| SezError::Other(format!("typing task failed: {error}")))?;
            match outcome {
                TypeOutcome::Typed => return Ok(()),
                // Pasting now would duplicate what already landed, so the text
                // is only handed over - the user decides where it goes.
                TypeOutcome::Partial => {
                    WinClipboard.set_text(text);
                    return Err(SezError::Other(
                        "insertion stopped mid-text - the full dictation is on your clipboard"
                            .to_owned(),
                    ));
                }
                TypeOutcome::Blocked => {}
            }
        }

        let ticket = self.engine.insert_with(text, send_chord)?;
        let engine = self.engine.clone();
        tokio::spawn(async move {
            tokio::time::sleep(RESTORE_DELAY).await;
            let _ = engine.restore(&ticket);
        });
        Ok(())
    }
}

/// Upper bound of events per `SendInput` call; one array is one atomic batch.
const TYPING_BATCH_EVENTS: usize = 512;

/// Types text as tagged unicode events, bypassing the clipboard entirely.
fn send_typed_text(text: &str) -> TypeOutcome {
    let events = build_typing_events(text);
    let mut accepted = 0usize;
    let mut rest = events.as_slice();

    while !rest.is_empty() {
        let (batch, tail) = rest.split_at(batch_len(rest, TYPING_BATCH_EVENTS));
        let inputs: Vec<INPUT> = batch.iter().map(type_input).collect();
        let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) } as usize;
        accepted += sent;
        if sent != inputs.len() {
            break;
        }
        rest = tail;
    }

    classify(accepted, events.len())
}

fn type_input(event: &TypeEvent) -> INPUT {
    let (virtual_key, scan_code, mut flags) = match event.unit {
        TypeUnit::Unicode(unit) => (VIRTUAL_KEY(0), unit, KEYEVENTF_UNICODE),
        TypeUnit::Key(TypedKey::Return) => (VK_RETURN, 0, KEYBD_EVENT_FLAGS(0)),
        TypeUnit::Key(TypedKey::Tab) => (VK_TAB, 0, KEYBD_EVENT_FLAGS(0)),
    };
    if event.state == KeyState::Up {
        flags |= KEYEVENTF_KEYUP;
    }

    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: virtual_key,
                wScan: scan_code,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: event.extra_info,
            },
        },
    }
}

fn send_chord(chord: &[KeyEvent; PASTE_CHORD_EVENT_COUNT]) -> u32 {
    let inputs = chord.map(|event| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: virtual_key(event.key),
                wScan: 0,
                dwFlags: match event.state {
                    KeyState::Down => KEYBD_EVENT_FLAGS(0),
                    KeyState::Up => KEYEVENTF_KEYUP,
                },
                time: 0,
                dwExtraInfo: event.extra_info,
            },
        },
    });
    unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) }
}

fn virtual_key(key: Key) -> VIRTUAL_KEY {
    match key {
        Key::Control => VK_CONTROL,
        Key::V => VK_V,
    }
}
