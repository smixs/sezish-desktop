// Throwaway spike (#5). Proves the insertion path is Unicode-safe for Uzbek
// apostrophes (U+02BB), Cyrillic and an em dash, in two machine-checkable halves:
//
//   1. Clipboard round-trip: SetClipboardData(CF_UNICODETEXT) -> GetClipboardData
//      -> compare byte-for-byte. This is where any charset/layout mangling would
//      show up — clipboard carries opaque UTF-16, no per-character translation.
//   2. One batched SendInput chord (Ctrl down / V down / V up / Ctrl up, tagged
//      via dwExtraInfo) returns 4 — delivery is proven. (The hook spike already
//      showed the OS accepts and routes this exact tagged chord.)
//
// The product inserter pastes into a foreign window the user already focused, so
// there is no SetForegroundWindow fight here — the spike deliberately does not
// synthesize one. A human still eyeballs a real paste into Notepad/Chrome as the
// final manual check.
use windows::Win32::Foundation::{HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_V,
};

const SELF_TAG: usize = 0x5E21_5E21;
// oʻzbekcha gʻoya — тест ҳ  (oʻ/gʻ use U+02BB MODIFIER LETTER TURNED COMMA)
const TEXT: &str = "oʻzbekcha gʻoya — тест ҳ";

fn set_clipboard(text: &str) {
    let mut utf16: Vec<u16> = text.encode_utf16().collect();
    utf16.push(0);
    let bytes = utf16.len() * std::mem::size_of::<u16>();
    unsafe {
        let hmem: HGLOBAL = GlobalAlloc(GMEM_MOVEABLE, bytes).expect("GlobalAlloc");
        let dst = GlobalLock(hmem) as *mut u16;
        std::ptr::copy_nonoverlapping(utf16.as_ptr(), dst, utf16.len());
        let _ = GlobalUnlock(hmem);
        OpenClipboard(None).expect("OpenClipboard");
        EmptyClipboard().expect("EmptyClipboard");
        SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(hmem.0))).expect("SetClipboardData");
        CloseClipboard().expect("CloseClipboard");
    }
}

fn read_clipboard() -> String {
    unsafe {
        OpenClipboard(None).expect("OpenClipboard(read)");
        let h = GetClipboardData(CF_UNICODETEXT.0 as u32).expect("GetClipboardData");
        let ptr = GlobalLock(HGLOBAL(h.0)) as *const u16;
        let mut len = 0usize;
        while *ptr.add(len) != 0 {
            len += 1;
        }
        let slice = std::slice::from_raw_parts(ptr, len);
        let s = String::from_utf16_lossy(slice);
        let _ = GlobalUnlock(HGLOBAL(h.0));
        CloseClipboard().expect("CloseClipboard(read)");
        s
    }
}

fn paste_chord_sent() -> u32 {
    let key = |vk: VIRTUAL_KEY, up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                },
                time: 0,
                dwExtraInfo: SELF_TAG,
            },
        },
    };
    let inputs = [
        key(VK_CONTROL, false),
        key(VK_V, false),
        key(VK_V, true),
        key(VK_CONTROL, true),
    ];
    unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) }
}

fn main() {
    println!("== paste spike ==");
    set_clipboard(TEXT);
    let back = read_clipboard();
    let roundtrip_ok = back == TEXT;
    let apos = back.matches('\u{02BB}').count();
    let sent = paste_chord_sent();

    println!("expected : {TEXT:?}");
    println!("clipboard: {back:?}");
    println!("clipboard_roundtrip={roundtrip_ok}");
    println!("apostrophes={apos} (want 2x U+02BB)");
    println!("chord_sent={sent} (want 4)");
    let pass = roundtrip_ok && apos == 2 && sent == 4;
    println!("RESULT: {}", if pass { "PASS" } else { "FAIL" });
    if !pass {
        std::process::exit(1);
    }
}
