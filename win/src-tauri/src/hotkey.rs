#[cfg(windows)]
mod windows_adapter {
    use sez_core::Clock;
    use sez_hotkey::{
        Command, Edge, HotkeyMode, HotkeyModeInterpreter, KeyEvent, Modifiers, Shortcut,
    };
    use std::cell::RefCell;
    use std::io;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc};
    use std::thread::{self, JoinHandle};
    use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, KillTimer, PeekMessageW, PostThreadMessageW,
        SetTimer, SetWindowsHookExW, UnhookWindowsHookEx, HHOOK, KBDLLHOOKSTRUCT, LLKHF_EXTENDED,
        MSG, PM_NOREMOVE, WH_KEYBOARD_LL, WM_APP, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
        WM_TIMER,
    };

    const CONTROL_MESSAGE: u32 = WM_APP + 0x5E21;
    const HEALTH_TIMER_ID: usize = 0x5E21;
    const HEALTH_INTERVAL_MS: u32 = 30_000;

    enum Control {
        SetMode(HotkeyMode, mpsc::SyncSender<()>),
        SetShortcut(Shortcut, mpsc::SyncSender<()>),
        Suspend(mpsc::SyncSender<()>),
        Resume(mpsc::SyncSender<()>),
        Shutdown,
    }

    struct HookContext {
        interpreter: HotkeyModeInterpreter,
        shortcut: Shortcut,
        combo_engaged: bool,
        suspended: bool,
        recording: Arc<AtomicBool>,
        swallowing_escape: bool,
        on_command: Box<dyn FnMut(Command)>,
        on_cancel: Box<dyn FnMut()>,
    }

    thread_local! {
        static HOOK_CONTEXT: RefCell<Option<HookContext>> = const { RefCell::new(None) };
    }

    pub struct HotkeyAdapter {
        control: mpsc::Sender<Control>,
        thread_id: u32,
        thread: Option<JoinHandle<()>>,
    }

    impl HotkeyAdapter {
        pub fn spawn(
            mode: HotkeyMode,
            shortcut: Shortcut,
            clock: Arc<dyn Clock>,
            recording: Arc<AtomicBool>,
            on_command: impl FnMut(Command) + Send + 'static,
            on_cancel: impl FnMut() + Send + 'static,
        ) -> io::Result<Self> {
            let (ready_tx, ready_rx) = mpsc::sync_channel(1);
            let (control_tx, control_rx) = mpsc::channel();
            let thread = thread::Builder::new()
                .name("sezish-hotkey-hook".to_owned())
                .spawn(move || {
                    let thread_id = unsafe { GetCurrentThreadId() };
                    let mut queue_probe = MSG::default();
                    unsafe {
                        let _ = PeekMessageW(&mut queue_probe, None, 0, 0, PM_NOREMOVE);
                    }

                    let recording_query = Arc::clone(&recording);
                    HOOK_CONTEXT.with(|slot| {
                        *slot.borrow_mut() = Some(HookContext {
                            interpreter: HotkeyModeInterpreter::new(mode, clock, move || {
                                recording_query.load(Ordering::Acquire)
                            }),
                            shortcut,
                            combo_engaged: false,
                            suspended: false,
                            recording,
                            swallowing_escape: false,
                            on_command: Box::new(on_command),
                            on_cancel: Box::new(on_cancel),
                        });
                    });

                    let mut hook = match install_hook() {
                        Ok(hook) => Some(hook),
                        Err(error) => {
                            let _ = ready_tx.send(Err(error.to_string()));
                            HOOK_CONTEXT.with(|slot| *slot.borrow_mut() = None);
                            return;
                        }
                    };
                    let timer =
                        unsafe { SetTimer(None, HEALTH_TIMER_ID, HEALTH_INTERVAL_MS, None) };
                    if timer == 0 {
                        if let Some(hook) = hook.take() {
                            unsafe {
                                let _ = UnhookWindowsHookEx(hook);
                            }
                        }
                        let _ =
                            ready_tx.send(Err("could not create hotkey health timer".to_owned()));
                        HOOK_CONTEXT.with(|slot| *slot.borrow_mut() = None);
                        return;
                    }
                    if ready_tx.send(Ok(thread_id)).is_err() {
                        cleanup_hook(timer, hook);
                        HOOK_CONTEXT.with(|slot| *slot.borrow_mut() = None);
                        return;
                    }

                    unsafe {
                        let mut message = MSG::default();
                        'messages: while GetMessageW(&mut message, None, 0, 0).0 > 0 {
                            match message.message {
                                CONTROL_MESSAGE => {
                                    while let Ok(control) = control_rx.try_recv() {
                                        match control {
                                            Control::SetMode(mode, acknowledgement) => {
                                                HOOK_CONTEXT.with(|slot| {
                                                    if let Some(context) =
                                                        slot.borrow_mut().as_mut()
                                                    {
                                                        context.interpreter.mode = mode;
                                                        context.combo_engaged = false;
                                                        context.interpreter.reset();
                                                    }
                                                });
                                                let _ = acknowledgement.send(());
                                            }
                                            Control::SetShortcut(shortcut, acknowledgement) => {
                                                HOOK_CONTEXT.with(|slot| {
                                                    if let Some(context) =
                                                        slot.borrow_mut().as_mut()
                                                    {
                                                        context.shortcut = shortcut;
                                                        context.combo_engaged = false;
                                                        context.interpreter.reset();
                                                    }
                                                });
                                                let _ = acknowledgement.send(());
                                            }
                                            Control::Suspend(acknowledgement) => {
                                                HOOK_CONTEXT.with(|slot| {
                                                    if let Some(context) =
                                                        slot.borrow_mut().as_mut()
                                                    {
                                                        context.suspended = true;
                                                        context.combo_engaged = false;
                                                        context.interpreter.reset();
                                                    }
                                                });
                                                let _ = acknowledgement.send(());
                                            }
                                            Control::Resume(acknowledgement) => {
                                                HOOK_CONTEXT.with(|slot| {
                                                    if let Some(context) =
                                                        slot.borrow_mut().as_mut()
                                                    {
                                                        context.suspended = false;
                                                        context.interpreter.reset();
                                                    }
                                                });
                                                let _ = acknowledgement.send(());
                                            }
                                            Control::Shutdown => break 'messages,
                                        }
                                    }
                                }
                                WM_TIMER if message.wParam.0 == timer => {
                                    if !prepare_health_rearm() {
                                        continue;
                                    }
                                    if let Some(previous) = hook.take() {
                                        let _ = UnhookWindowsHookEx(previous);
                                    }
                                    hook = match install_hook() {
                                        Ok(hook) => Some(hook),
                                        Err(error) => {
                                            // Retried on the next tick; without
                                            // this line a dead hotkey is invisible.
                                            crate::obs::log(&format!(
                                                "hotkey hook rearm failed: {error}"
                                            ));
                                            None
                                        }
                                    };
                                }
                                _ => {
                                    DispatchMessageW(&message);
                                }
                            }
                        }
                    }

                    cleanup_hook(timer, hook);
                    HOOK_CONTEXT.with(|slot| *slot.borrow_mut() = None);
                })?;

            match ready_rx.recv() {
                Ok(Ok(thread_id)) => Ok(Self {
                    control: control_tx,
                    thread_id,
                    thread: Some(thread),
                }),
                Ok(Err(message)) => {
                    let _ = thread.join();
                    Err(io::Error::other(message))
                }
                Err(_) => {
                    let _ = thread.join();
                    Err(io::Error::other(
                        "hotkey hook stopped before reporting readiness",
                    ))
                }
            }
        }

        pub fn set_mode(&self, mode: HotkeyMode) -> io::Result<()> {
            let (ack_tx, ack_rx) = mpsc::sync_channel(1);
            self.control
                .send(Control::SetMode(mode, ack_tx))
                .map_err(|_| io::Error::other("hotkey hook is not running"))?;
            self.wake()?;
            ack_rx
                .recv()
                .map_err(|_| io::Error::other("hotkey hook stopped during mode change"))
        }

        pub fn set_shortcut(&self, shortcut: Shortcut) -> io::Result<()> {
            let (ack_tx, ack_rx) = mpsc::sync_channel(1);
            self.control
                .send(Control::SetShortcut(shortcut, ack_tx))
                .map_err(|_| io::Error::other("hotkey hook is not running"))?;
            self.wake()?;
            ack_rx
                .recv()
                .map_err(|_| io::Error::other("hotkey hook stopped during shortcut change"))
        }

        pub fn suspend(&self) -> io::Result<()> {
            let (ack_tx, ack_rx) = mpsc::sync_channel(1);
            self.control
                .send(Control::Suspend(ack_tx))
                .map_err(|_| io::Error::other("hotkey hook is not running"))?;
            self.wake()?;
            ack_rx
                .recv()
                .map_err(|_| io::Error::other("hotkey hook stopped during suspend"))
        }

        pub fn resume(&self) -> io::Result<()> {
            let (ack_tx, ack_rx) = mpsc::sync_channel(1);
            self.control
                .send(Control::Resume(ack_tx))
                .map_err(|_| io::Error::other("hotkey hook is not running"))?;
            self.wake()?;
            ack_rx
                .recv()
                .map_err(|_| io::Error::other("hotkey hook stopped during resume"))
        }

        fn wake(&self) -> io::Result<()> {
            unsafe {
                PostThreadMessageW(self.thread_id, CONTROL_MESSAGE, WPARAM(0), LPARAM(0))
                    .map_err(|error| io::Error::other(error.to_string()))
            }
        }
    }

    impl Drop for HotkeyAdapter {
        fn drop(&mut self) {
            let _ = self.control.send(Control::Shutdown);
            let _ = self.wake();
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    fn install_hook() -> io::Result<HHOOK> {
        unsafe {
            let module =
                GetModuleHandleW(None).map_err(|error| io::Error::other(error.to_string()))?;
            let instance: HINSTANCE = module.into();
            SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), Some(instance), 0)
                .map_err(|error| io::Error::other(error.to_string()))
        }
    }

    fn cleanup_hook(timer: usize, hook: Option<HHOOK>) {
        unsafe {
            let _ = KillTimer(None, timer);
            if let Some(hook) = hook {
                let _ = UnhookWindowsHookEx(hook);
            }
        }
    }

    fn prepare_health_rearm() -> bool {
        HOOK_CONTEXT.with(|slot| {
            if let Some(context) = slot.borrow_mut().as_mut() {
                let hotkey_down = shortcut_currently_held(&context.shortcut);
                if context.interpreter.mode == HotkeyMode::Hold
                    && context.recording.load(Ordering::Acquire)
                    && hotkey_down
                {
                    return false;
                }
                let command = context.interpreter.key_released();
                context.interpreter.reset();
                if command != Command::None {
                    (context.on_command)(command);
                }
            }
            true
        })
    }

    unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 {
            let event = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
            let message = wparam.0 as u32;
            let key_down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
            let key_up = message == WM_KEYUP || message == WM_SYSKEYUP;

            if event.vkCode == u32::from(windows::Win32::UI::Input::KeyboardAndMouse::VK_ESCAPE.0) {
                let swallowed = HOOK_CONTEXT.with(|slot| {
                    let mut slot = slot.borrow_mut();
                    let Some(context) = slot.as_mut() else {
                        return false;
                    };
                    if key_up && context.swallowing_escape {
                        context.swallowing_escape = false;
                        return true;
                    }
                    if !key_down {
                        return false;
                    }
                    if context.swallowing_escape {
                        return true;
                    }
                    if context.recording.load(Ordering::Acquire) && no_modifiers_pressed() {
                        context.swallowing_escape = true;
                        (context.on_cancel)();
                        return true;
                    }
                    false
                });
                if swallowed {
                    return LRESULT(1);
                }
            } else if key_down || key_up {
                let swallow = HOOK_CONTEXT.with(|slot| {
                    let mut slot = slot.borrow_mut();
                    let Some(context) = slot.as_mut() else {
                        return false;
                    };
                    if context.suspended {
                        return false;
                    }
                    let key_event = KeyEvent {
                        vk: event.vkCode as u16,
                        extended: event.flags.0 & LLKHF_EXTENDED.0 != 0,
                        key_down,
                        active: active_modifiers(),
                    };
                    let decision = context.shortcut.evaluate(&key_event, context.combo_engaged);
                    context.combo_engaged = decision.engaged;
                    if let Some(edge) = decision.edge {
                        crate::obs::log(&format!(
                            "hook edge={edge:?} vk=0x{:X} swallow={}",
                            key_event.vk, decision.swallow
                        ));
                        let command = match edge {
                            Edge::Press => context.interpreter.key_pressed(),
                            Edge::Release => context.interpreter.key_released(),
                        };
                        if command != Command::None {
                            (context.on_command)(command);
                        }
                    }
                    decision.swallow
                });
                if swallow {
                    return LRESULT(1);
                }
            }
        }

        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    fn no_modifiers_pressed() -> bool {
        [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN]
            .into_iter()
            .all(|key| unsafe { GetAsyncKeyState(i32::from(key.0)) } >= 0)
    }

    fn is_pressed(vk: u16) -> bool {
        unsafe { GetAsyncKeyState(i32::from(vk)) < 0 }
    }

    /// The generic modifiers currently held, read straight from `GetAsyncKeyState`.
    fn active_modifiers() -> Modifiers {
        let mut mods = Modifiers::empty();
        if is_pressed(VK_CONTROL.0) {
            mods.insert(Modifiers::CTRL);
        }
        if is_pressed(VK_MENU.0) {
            mods.insert(Modifiers::ALT);
        }
        if is_pressed(VK_SHIFT.0) {
            mods.insert(Modifiers::SHIFT);
        }
        if is_pressed(VK_LWIN.0) || is_pressed(VK_RWIN.0) {
            mods.insert(Modifiers::WIN);
        }
        mods
    }

    /// Whether the configured shortcut is physically held right now: the modifier key
    /// itself for `ModifierOnly`, or the main key plus its required modifiers for a combo.
    fn shortcut_currently_held(shortcut: &Shortcut) -> bool {
        match shortcut {
            Shortcut::ModifierOnly { vk } => is_pressed(*vk),
            Shortcut::Key { vk, mods } => is_pressed(*vk) && active_modifiers().contains(*mods),
        }
    }
}

#[cfg(not(windows))]
mod windows_adapter {
    use sez_core::Clock;
    use sez_hotkey::{Command, HotkeyMode, Shortcut};
    use std::io;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    pub struct HotkeyAdapter;

    impl HotkeyAdapter {
        pub fn spawn(
            _mode: HotkeyMode,
            _shortcut: Shortcut,
            _clock: Arc<dyn Clock>,
            _recording: Arc<AtomicBool>,
            _on_command: impl FnMut(Command) + Send + 'static,
            _on_cancel: impl FnMut() + Send + 'static,
        ) -> io::Result<Self> {
            Ok(Self)
        }

        pub fn set_mode(&self, _mode: HotkeyMode) -> io::Result<()> {
            Ok(())
        }

        pub fn set_shortcut(&self, _shortcut: Shortcut) -> io::Result<()> {
            Ok(())
        }

        pub fn suspend(&self) -> io::Result<()> {
            Ok(())
        }

        pub fn resume(&self) -> io::Result<()> {
            Ok(())
        }
    }
}

pub use windows_adapter::HotkeyAdapter;
