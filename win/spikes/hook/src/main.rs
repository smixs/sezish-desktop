// Throwaway spike (#4). WH_KEYBOARD_LL on a dedicated thread + GetMessageW pump.
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_V,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, KBDLLHOOKSTRUCT,
    LLKHF_EXTENDED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
};

// Sentinel stamped into dwExtraInfo of every event we synthesize, so the hook can
// tell our own injections apart from real hardware and from foreign injectors.
const SELF_TAG: usize = 0x5E21_5E21;
const VK_RCONTROL_SCAN_EXTENDED: bool = true; // right ctrl arrives with the extended flag

static RCTRL_DOWN: AtomicBool = AtomicBool::new(false);
static LAST_EDGE_MS: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn delta() -> u64 {
    let t = now_ms();
    let prev = LAST_EDGE_MS.swap(t, Ordering::Relaxed);
    if prev == 0 {
        0
    } else {
        t - prev
    }
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let kb = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let msg = wparam.0 as u32;
        let is_down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
        let is_up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
        let vk = kb.vkCode;
        let extended = (kb.flags.0 & LLKHF_EXTENDED.0) != 0;
        let self_injected = kb.dwExtraInfo == SELF_TAG;

        // Ctrl vkCode is 0x11 (VK_CONTROL) for both sides at the LL hook; right vs left
        // is the extended flag. VK_RCONTROL (0xA3) may also appear on some drivers.
        let is_right_ctrl =
            (vk == VK_CONTROL.0 as u32 && extended == VK_RCONTROL_SCAN_EXTENDED) || vk == 0xA3;
        let is_ctrl = vk == VK_CONTROL.0 as u32 || vk == 0xA2 || vk == 0xA3;
        let is_v = vk == VK_V.0 as u32;

        if self_injected {
            if is_down && (is_ctrl || is_v) {
                println!("IGNORED self-injection (tag matched): vk=0x{vk:02X}");
            }
            // Let it through to the OS so the paste actually happens, but never treat
            // it as a user hotkey.
            return CallNextHookEx(None, code, wparam, lparam);
        }

        if is_right_ctrl && is_down {
            if !RCTRL_DOWN.swap(true, Ordering::Relaxed) {
                println!("RCTRL DOWN  (+{} ms)", delta());
            } // else: auto-repeat, collapsed
        } else if is_right_ctrl && is_up {
            RCTRL_DOWN.store(false, Ordering::Relaxed);
            println!("RCTRL UP    (+{} ms)", delta());
        } else if is_ctrl && !is_right_ctrl && is_down {
            println!("left ctrl ignored (not our key)");
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

fn inject_tagged_ctrl_v() {
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
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    println!("(injected tagged Ctrl+V, SendInput returned {sent})");
}

fn main() {
    println!("== hook spike ==");
    println!(
        "hold/tap Right Ctrl; press Left Ctrl; watch for IGNORED after ~3s. Ctrl+C to quit.\n"
    );

    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_secs(3));
        inject_tagged_ctrl_v();
    });

    unsafe {
        let hinstance: HINSTANCE = GetModuleHandleW(None).unwrap().into();
        let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), Some(hinstance), 0)
            .expect("SetWindowsHookExW failed");
        let _ = hook;
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            DispatchMessageW(&msg);
        }
    }
}
