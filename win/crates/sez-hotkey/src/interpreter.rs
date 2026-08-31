use sez_core::Clock;
use std::sync::Arc;
use std::time::Duration;

/// How the dictation hotkey drives recording.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyMode {
    /// Recording runs while the hotkey is held.
    Hold,
    /// One press starts recording and the next press stops it.
    Toggle,
}

/// Command emitted by the interpreter for one press or release edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Start,
    Stop,
    None,
}

/// Pure interpreter between raw key press/release edges and dictation commands.
/// Instead of a hands-free latch, it consults a live is_recording query on
/// every call, so an externally ended take (Esc cancel, failed start, mode
/// flip) can never strand stale state. Not Send/Sync by design: owned and
/// driven exclusively by the thread that installs the hotkey monitor (mirrors
/// the Swift MainActor note).
pub struct HotkeyModeInterpreter {
    pub mode: HotkeyMode,
    clock: Arc<dyn Clock>,
    is_recording: Box<dyn Fn() -> bool>,
    is_pressed: bool,
    last_accepted_press: Option<Duration>,
}

impl HotkeyModeInterpreter {
    /// Toggle-mode debounce window. Hold mode is EXEMPT (a fast consecutive
    /// push-to-talk press must never be eaten). Matches
    /// HotkeyModeInterpreter.toggleCooldown (0.5 s).
    pub const TOGGLE_COOLDOWN: Duration = Duration::from_millis(500);

    /// is_recording is captured here (not passed per-call) and invoked FRESH
    /// on every key_pressed/key_released call, this is what live query, not a
    /// latch, means.
    pub fn new(
        mode: HotkeyMode,
        clock: Arc<dyn Clock>,
        is_recording: impl Fn() -> bool + 'static,
    ) -> Self {
        Self {
            mode,
            clock,
            is_recording: Box::new(is_recording),
            is_pressed: false,
            last_accepted_press: None,
        }
    }

    pub fn key_pressed(&mut self) -> Command {
        if self.is_pressed {
            return Command::None;
        }

        let now = self.clock.now();
        if self.mode == HotkeyMode::Toggle
            && self.last_accepted_press.is_some_and(|last| {
                now.saturating_sub(last) < HotkeyModeInterpreter::TOGGLE_COOLDOWN
            })
        {
            return Command::None;
        }

        self.is_pressed = true;
        self.last_accepted_press = Some(now);
        if (self.is_recording)() {
            return if self.mode == HotkeyMode::Toggle {
                Command::Stop
            } else {
                Command::None
            };
        }
        Command::Start
    }

    pub fn key_released(&mut self) -> Command {
        if !self.is_pressed {
            return Command::None;
        }

        self.is_pressed = false;
        match self.mode {
            HotkeyMode::Hold if (self.is_recording)() => Command::Stop,
            HotkeyMode::Hold | HotkeyMode::Toggle => Command::None,
        }
    }

    /// Forgets any in-flight press and cooldown (mode flip, monitor reinstall).
    pub fn reset(&mut self) {
        self.is_pressed = false;
        self.last_accepted_press = None;
    }
}

#[cfg(test)]
mod tests {
    use super::{Command, HotkeyMode, HotkeyModeInterpreter};
    use sez_core::test_util::MockClock;
    use std::cell::Cell;
    use std::rc::Rc;
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn toggle_repeat_within_cooldown_and_its_release_are_ignored() {
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let is_recording = Rc::new(Cell::new(false));
        let query = Rc::clone(&is_recording);
        let mut interpreter =
            HotkeyModeInterpreter::new(HotkeyMode::Toggle, clock.clone(), move || query.get());

        assert_eq!(interpreter.key_pressed(), Command::Start);
        is_recording.set(true);
        assert_eq!(interpreter.key_released(), Command::None);

        clock.advance(Duration::from_millis(100));
        assert_eq!(interpreter.key_pressed(), Command::None);
        assert_eq!(interpreter.key_released(), Command::None);
    }

    #[test]
    fn hold_is_exempt_from_cooldown() {
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let is_recording = Rc::new(Cell::new(false));
        let query = Rc::clone(&is_recording);
        let mut interpreter =
            HotkeyModeInterpreter::new(HotkeyMode::Hold, clock, move || query.get());

        assert_eq!(interpreter.key_pressed(), Command::Start);
        is_recording.set(true);
        assert_eq!(interpreter.key_released(), Command::Stop);
        is_recording.set(false);

        assert_eq!(interpreter.key_pressed(), Command::Start);
        is_recording.set(true);
        assert_eq!(interpreter.key_released(), Command::Stop);
    }

    #[test]
    fn auto_repeat_without_release_is_ignored_without_corrupting_state() {
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let is_recording = Rc::new(Cell::new(false));
        let query = Rc::clone(&is_recording);
        let mut interpreter =
            HotkeyModeInterpreter::new(HotkeyMode::Hold, clock, move || query.get());

        assert_eq!(interpreter.key_pressed(), Command::Start);
        is_recording.set(true);
        assert_eq!(interpreter.key_pressed(), Command::None);
        assert_eq!(interpreter.key_released(), Command::Stop);
    }

    #[test]
    fn external_cancel_then_toggle_press_starts_from_live_query() {
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let is_recording = Rc::new(Cell::new(false));
        let query = Rc::clone(&is_recording);
        let mut interpreter =
            HotkeyModeInterpreter::new(HotkeyMode::Toggle, clock.clone(), move || query.get());

        assert_eq!(interpreter.key_pressed(), Command::Start);
        is_recording.set(true);
        assert_eq!(interpreter.key_released(), Command::None);

        is_recording.set(false);
        clock.advance(HotkeyModeInterpreter::TOGGLE_COOLDOWN);
        assert_eq!(interpreter.key_pressed(), Command::Start);
    }

    #[test]
    fn reset_clears_pressed_state_and_cooldown() {
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let is_recording = Rc::new(Cell::new(false));
        let query = Rc::clone(&is_recording);
        let mut interpreter =
            HotkeyModeInterpreter::new(HotkeyMode::Toggle, clock, move || query.get());

        assert_eq!(interpreter.key_pressed(), Command::Start);
        is_recording.set(true);

        interpreter.reset();
        is_recording.set(false);
        assert_eq!(interpreter.key_pressed(), Command::Start);
    }
}
