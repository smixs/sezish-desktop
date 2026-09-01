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

/// How stale the last swallowed press may be before the key counts as released.
/// Windows auto-repeat re-delivers a held key every ~30 ms once its repeat delay
/// (at most 1 s) has passed, and every repeat produces a fresh `Edge::Press`, so
/// two seconds of silence means the key really is up.
pub const SWALLOWED_PRESS_HOLD_WINDOW: Duration = Duration::from_secs(2);

/// Whether the keyboard hook may be torn down and reinstalled right now. The
/// rearm emits a synthetic release, so a hold-mode take in progress would be cut
/// off mid-word; skip the rearm while the hotkey is still down.
///
/// `physically_held` is what `GetAsyncKeyState` reports and only works for events
/// the hook lets through. A swallowed `.key` press never reaches the async key
/// state, so for those the caller passes `press_age`: the time since the last
/// swallowed press edge.
pub fn hold_rearm_allowed(
    mode: HotkeyMode,
    recording: bool,
    physically_held: bool,
    press_age: Option<Duration>,
    hold_window: Duration,
) -> bool {
    if mode != HotkeyMode::Hold || !recording {
        return true;
    }
    let held = physically_held || press_age.is_some_and(|age| age <= hold_window);
    !held
}

#[cfg(test)]
mod tests {
    use super::{
        hold_rearm_allowed, Command, HotkeyMode, HotkeyModeInterpreter, SWALLOWED_PRESS_HOLD_WINDOW,
    };
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

    #[test]
    fn swallowed_key_held_through_auto_repeat_blocks_the_rearm() {
        // F9 held: auto-repeat refreshed the press a moment ago, no async key state.
        assert!(!hold_rearm_allowed(
            HotkeyMode::Hold,
            true,
            false,
            Some(Duration::from_millis(120)),
            SWALLOWED_PRESS_HOLD_WINDOW,
        ));
    }

    #[test]
    fn swallowed_key_released_with_a_lost_release_allows_the_rearm() {
        // The key came up but its release edge never arrived: auto-repeat stopped,
        // so the rearm may run and its synthetic release ends the stuck take.
        assert!(hold_rearm_allowed(
            HotkeyMode::Hold,
            true,
            false,
            Some(Duration::from_secs(5)),
            SWALLOWED_PRESS_HOLD_WINDOW,
        ));
    }

    #[test]
    fn modifier_only_still_decides_by_the_async_key_state() {
        assert!(!hold_rearm_allowed(
            HotkeyMode::Hold,
            true,
            true,
            None,
            SWALLOWED_PRESS_HOLD_WINDOW,
        ));
        assert!(hold_rearm_allowed(
            HotkeyMode::Hold,
            true,
            false,
            None,
            SWALLOWED_PRESS_HOLD_WINDOW,
        ));
    }

    #[test]
    fn idle_or_toggle_never_blocks_the_rearm() {
        assert!(hold_rearm_allowed(
            HotkeyMode::Hold,
            false,
            true,
            Some(Duration::ZERO),
            SWALLOWED_PRESS_HOLD_WINDOW,
        ));
        assert!(hold_rearm_allowed(
            HotkeyMode::Toggle,
            true,
            true,
            Some(Duration::ZERO),
            SWALLOWED_PRESS_HOLD_WINDOW,
        ));
    }
}
