use sez_core::{Clock, SezError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Sentinel stamped on every synthetic keyboard event.
pub const SELF_INJECTION_TAG: usize = 0x5E21_5E21;

/// Maximum number of safe SendInput attempts when no events were accepted.
pub const MAX_SEND_ATTEMPTS: usize = 3;

/// Delay before a successful insertion may restore the previous clipboard.
pub const RESTORE_DELAY: Duration = Duration::from_millis(625);

/// Number of events in one batched Ctrl+V chord.
pub const PASTE_CHORD_EVENT_COUNT: usize = 4;

/// Logical key in the synthetic paste chord.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Control,
    V,
}

/// Press/release edge in the synthetic paste chord.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyState {
    Down,
    Up,
}

/// Cross-platform description of one tagged keyboard event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    /// Logical key.
    pub key: Key,
    /// Whether the key is pressed or released.
    pub state: KeyState,
    /// Marker copied into Win32 `dwExtraInfo`.
    pub extra_info: usize,
}

/// Builds one complete, ordered Ctrl+V input batch.
pub fn build_paste_chord() -> [KeyEvent; PASTE_CHORD_EVENT_COUNT] {
    [
        KeyEvent {
            key: Key::Control,
            state: KeyState::Down,
            extra_info: SELF_INJECTION_TAG,
        },
        KeyEvent {
            key: Key::V,
            state: KeyState::Down,
            extra_info: SELF_INJECTION_TAG,
        },
        KeyEvent {
            key: Key::V,
            state: KeyState::Up,
            extra_info: SELF_INJECTION_TAG,
        },
        KeyEvent {
            key: Key::Control,
            state: KeyState::Up,
            extra_info: SELF_INJECTION_TAG,
        },
    ]
}

/// Result of attempting one batched paste chord.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendOutcome {
    Sent,
    Blocked,
}

/// Sends the full chord, retrying only calls which accepted zero events.
pub fn send_with_retry<F>(mut send_once: F) -> SendOutcome
where
    F: FnMut(&[KeyEvent; PASTE_CHORD_EVENT_COUNT]) -> u32,
{
    let chord = build_paste_chord();
    for _ in 0..MAX_SEND_ATTEMPTS {
        match send_once(&chord) {
            sent if sent == PASTE_CHORD_EVENT_COUNT as u32 => return SendOutcome::Sent,
            0 => continue,
            _ => return SendOutcome::Blocked,
        }
    }
    SendOutcome::Blocked
}

/// Clipboard boundary local to this adapter crate.
pub trait Clipboard: Send + Sync {
    fn get_text(&self) -> Option<String>;
    fn set_text(&self, text: &str);
}

/// Opaque restore work created only after a successful paste.
#[derive(Debug)]
pub struct RestoreTicket {
    generation: u64,
    deadline: Duration,
    placed_text: String,
    prior_text: Option<String>,
}

/// Observable result of evaluating scheduled clipboard restore work.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestoreOutcome {
    Pending,
    Restored,
    Skipped,
}

/// Cross-platform insertion and generation-tracked restore policy.
pub struct InsertionEngine<C, K> {
    clipboard: Arc<C>,
    clock: Arc<K>,
    generation: Arc<Mutex<u64>>,
}

impl<C, K> InsertionEngine<C, K>
where
    C: Clipboard,
    K: Clock,
{
    /// Creates insertion policy over injected clipboard and monotonic time.
    pub fn new(clipboard: Arc<C>, clock: Arc<K>) -> Self {
        Self {
            clipboard,
            clock,
            generation: Arc::new(Mutex::new(0)),
        }
    }

    /// Stages text, sends one paste batch, and returns restore work on success.
    pub fn insert_with<F>(&self, text: &str, send_once: F) -> Result<RestoreTicket, SezError>
    where
        F: FnMut(&[KeyEvent; PASTE_CHORD_EVENT_COUNT]) -> u32,
    {
        let generation = {
            let mut current = self.generation.lock().map_err(|_| {
                SezError::Other("clipboard restore generation is unavailable".to_owned())
            })?;
            *current = (*current).checked_add(1).ok_or_else(|| {
                SezError::Other("clipboard restore generation overflowed".to_owned())
            })?;
            *current
        };
        let prior_text = self.clipboard.get_text();
        self.clipboard.set_text(text);

        if self.clipboard.get_text().as_deref() != Some(text)
            || send_with_retry(send_once) != SendOutcome::Sent
        {
            return Err(manual_paste_error());
        }

        Ok(RestoreTicket {
            generation,
            deadline: self.clock.now().saturating_add(RESTORE_DELAY),
            placed_text: text.to_owned(),
            prior_text,
        })
    }

    /// Evaluates restore work without waiting or blocking.
    pub fn restore(&self, ticket: &RestoreTicket) -> RestoreOutcome {
        if self.clock.now() < ticket.deadline {
            return RestoreOutcome::Pending;
        }

        let current_generation = match self.generation.lock() {
            Ok(current) => current,
            Err(_) => return RestoreOutcome::Skipped,
        };
        if *current_generation != ticket.generation
            || self.clipboard.get_text().as_deref() != Some(ticket.placed_text.as_str())
        {
            return RestoreOutcome::Skipped;
        }

        self.clipboard
            .set_text(ticket.prior_text.as_deref().unwrap_or(""));
        RestoreOutcome::Restored
    }
}

impl<C, K> Clone for InsertionEngine<C, K> {
    fn clone(&self) -> Self {
        Self {
            clipboard: Arc::clone(&self.clipboard),
            clock: Arc::clone(&self.clock),
            generation: Arc::clone(&self.generation),
        }
    }
}

fn manual_paste_error() -> SezError {
    SezError::Other(
        "insertion blocked - text is on your clipboard; press Ctrl+V manually to paste".to_owned(),
    )
}

#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use windows::{WinClipboard, WindowsInserter};

#[cfg(test)]
pub mod test_util {
    use super::Clipboard;
    use std::sync::{Arc, Mutex};

    #[derive(Clone)]
    pub struct MockClipboard {
        state: Arc<Mutex<MockClipboardState>>,
    }

    struct MockClipboardState {
        current: Option<String>,
        set_calls: Vec<String>,
    }

    impl MockClipboard {
        pub fn new(current: Option<&str>) -> Self {
            Self {
                state: Arc::new(Mutex::new(MockClipboardState {
                    current: current.map(str::to_owned),
                    set_calls: Vec::new(),
                })),
            }
        }

        pub fn replace_current(&self, current: Option<&str>) {
            self.state
                .lock()
                .expect("mock clipboard mutex poisoned")
                .current = current.map(str::to_owned);
        }

        pub fn current(&self) -> Option<String> {
            self.state
                .lock()
                .expect("mock clipboard mutex poisoned")
                .current
                .clone()
        }

        pub fn set_calls(&self) -> Vec<String> {
            self.state
                .lock()
                .expect("mock clipboard mutex poisoned")
                .set_calls
                .clone()
        }
    }

    impl Clipboard for MockClipboard {
        fn get_text(&self) -> Option<String> {
            self.current()
        }

        fn set_text(&self, text: &str) {
            let mut state = self.state.lock().expect("mock clipboard mutex poisoned");
            state.current = Some(text.to_owned());
            state.set_calls.push(text.to_owned());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_util::MockClipboard;
    use super::{
        build_paste_chord, send_with_retry, InsertionEngine, Key, KeyEvent, KeyState,
        RestoreOutcome, SendOutcome, MAX_SEND_ATTEMPTS, RESTORE_DELAY, SELF_INJECTION_TAG,
    };
    use sez_core::test_util::MockClock;
    use std::collections::VecDeque;
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn paste_chord_is_one_tagged_ctrl_down_v_down_v_up_ctrl_up_batch() {
        let chord = build_paste_chord();

        assert_eq!(
            chord,
            [
                KeyEvent {
                    key: Key::Control,
                    state: KeyState::Down,
                    extra_info: 0x5E21_5E21,
                },
                KeyEvent {
                    key: Key::V,
                    state: KeyState::Down,
                    extra_info: 0x5E21_5E21,
                },
                KeyEvent {
                    key: Key::V,
                    state: KeyState::Up,
                    extra_info: 0x5E21_5E21,
                },
                KeyEvent {
                    key: Key::Control,
                    state: KeyState::Up,
                    extra_info: 0x5E21_5E21,
                },
            ]
        );
        assert_eq!(chord.len(), 4);
        assert!(chord
            .iter()
            .all(|event| event.extra_info == SELF_INJECTION_TAG));
    }

    #[test]
    fn zero_event_sends_are_retried_until_the_full_batch_is_sent() {
        let mut results = VecDeque::from([0, 0, 4]);
        let mut calls = 0;

        let outcome = send_with_retry(|_| {
            calls += 1;
            results.pop_front().expect("unexpected send attempt")
        });

        assert_eq!(outcome, SendOutcome::Sent);
        assert_eq!(calls, 3);
    }

    #[test]
    fn all_zero_event_sends_stop_at_the_retry_bound() {
        let mut calls = 0;

        let outcome = send_with_retry(|_| {
            calls += 1;
            0
        });

        assert_eq!(outcome, SendOutcome::Blocked);
        assert_eq!(calls, MAX_SEND_ATTEMPTS);
    }

    #[test]
    fn a_partial_send_is_blocked_without_retrying() {
        let mut calls = 0;

        let outcome = send_with_retry(|_| {
            calls += 1;
            2
        });

        assert_eq!(outcome, SendOutcome::Blocked);
        assert_eq!(calls, 1);
    }

    #[test]
    fn due_restore_replaces_our_unchanged_text_with_the_prior_clipboard() {
        let clipboard = Arc::new(MockClipboard::new(Some("old clipboard")));
        let clock = Arc::new(MockClock::new(Duration::from_secs(10)));
        let engine = InsertionEngine::new(Arc::clone(&clipboard), Arc::clone(&clock));
        let ticket = engine
            .insert_with("dictated text", |_| 4)
            .expect("insertion should succeed");
        clock.advance(RESTORE_DELAY);

        let outcome = engine.restore(&ticket);

        assert_eq!(outcome, RestoreOutcome::Restored);
        assert_eq!(
            clipboard.set_calls(),
            vec!["dictated text".to_owned(), "old clipboard".to_owned()]
        );
        assert_eq!(clipboard.current().as_deref(), Some("old clipboard"));
    }

    #[test]
    fn due_restore_preserves_clipboard_content_changed_by_the_user() {
        let clipboard = Arc::new(MockClipboard::new(Some("old clipboard")));
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let engine = InsertionEngine::new(Arc::clone(&clipboard), Arc::clone(&clock));
        let ticket = engine
            .insert_with("dictated text", |_| 4)
            .expect("insertion should succeed");
        clipboard.replace_current(Some("user copied this"));
        clock.advance(RESTORE_DELAY);

        let outcome = engine.restore(&ticket);

        assert_eq!(outcome, RestoreOutcome::Skipped);
        assert_eq!(clipboard.set_calls(), vec!["dictated text".to_owned()]);
        assert_eq!(clipboard.current().as_deref(), Some("user copied this"));
    }

    #[test]
    fn failed_insertion_leaves_text_in_hand_and_suppresses_restore() {
        let clipboard = Arc::new(MockClipboard::new(Some("old clipboard")));
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let engine = InsertionEngine::new(Arc::clone(&clipboard), Arc::clone(&clock));

        let error = engine
            .insert_with("dictated text", |_| 2)
            .expect_err("partial send must fail");
        clock.advance(RESTORE_DELAY);

        let message = error.to_string();
        assert!(message.contains("clipboard"));
        assert!(message.contains("Ctrl+V manually"));
        assert_eq!(clipboard.set_calls(), vec!["dictated text".to_owned()]);
        assert_eq!(clipboard.current().as_deref(), Some("dictated text"));
    }

    #[test]
    fn successful_insertion_sets_text_then_restores_after_the_window() {
        let clipboard = Arc::new(MockClipboard::new(Some("before")));
        let clock = Arc::new(MockClock::new(Duration::from_secs(20)));
        let engine = InsertionEngine::new(Arc::clone(&clipboard), Arc::clone(&clock));
        let mut send_calls = 0;

        let ticket = engine
            .insert_with("oʻzbekcha gʻoya", |_| {
                send_calls += 1;
                4
            })
            .expect("full send should succeed");

        assert_eq!(send_calls, 1);
        assert_eq!(clipboard.current().as_deref(), Some("oʻzbekcha gʻoya"));
        clock.advance(RESTORE_DELAY);
        assert_eq!(engine.restore(&ticket), RestoreOutcome::Restored);
        assert_eq!(clipboard.current().as_deref(), Some("before"));
    }

    #[test]
    fn newer_insertion_invalidates_an_older_restore_ticket() {
        let clipboard = Arc::new(MockClipboard::new(Some("before")));
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let engine = InsertionEngine::new(Arc::clone(&clipboard), Arc::clone(&clock));
        let older = engine
            .insert_with("first", |_| 4)
            .expect("first insertion should succeed");
        let _newer = engine
            .insert_with("second", |_| 4)
            .expect("second insertion should succeed");
        clock.advance(RESTORE_DELAY);

        assert_eq!(engine.restore(&older), RestoreOutcome::Skipped);
        assert_eq!(clipboard.current().as_deref(), Some("second"));
    }

    #[test]
    fn restore_before_the_deadline_remains_pending() {
        let clipboard = Arc::new(MockClipboard::new(None));
        let clock = Arc::new(MockClock::new(Duration::ZERO));
        let engine = InsertionEngine::new(Arc::clone(&clipboard), Arc::clone(&clock));
        let ticket = engine
            .insert_with("dictated text", |_| 4)
            .expect("insertion should succeed");

        assert_eq!(engine.restore(&ticket), RestoreOutcome::Pending);
        assert_eq!(clipboard.set_calls(), vec!["dictated text".to_owned()]);
    }
}
