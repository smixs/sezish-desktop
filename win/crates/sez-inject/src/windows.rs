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
    VIRTUAL_KEY, VK_CONTROL, VK_V,
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
        }
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
    async fn insert(&self, text: &str) -> Result<(), SezError> {
        let ticket = self.engine.insert_with(text, send_chord)?;
        let engine = self.engine.clone();
        tokio::spawn(async move {
            tokio::time::sleep(RESTORE_DELAY).await;
            let _ = engine.restore(&ticket);
        });
        Ok(())
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
