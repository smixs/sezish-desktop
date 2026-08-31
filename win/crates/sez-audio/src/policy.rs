use sez_core::Clock;
use std::time::Duration;

/// Result of applying the start side of [`IdleClosePolicy`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartDisposition {
    /// No warm stream existed, so the caller must open one.
    FreshOpen,
    /// A still-warm stream existed and should be reused.
    ReusedWarm,
}

/// Deterministic warm-stream idle-close state machine.
///
/// This object never starts a timer. Every transition reads only the
/// caller-provided [`Clock`].
pub struct IdleClosePolicy {
    idle_timeout: Duration,
    stopped_at: Option<Duration>,
    warm: bool,
    fresh_open_count: u64,
    reuse_count: u64,
}

impl IdleClosePolicy {
    /// Creates a cold policy with the supplied idle timeout.
    pub fn new(idle_timeout: Duration) -> Self {
        Self {
            idle_timeout,
            stopped_at: None,
            warm: false,
            fresh_open_count: 0,
            reuse_count: 0,
        }
    }

    /// Records a start and reports whether the caller should reuse or open.
    pub fn on_start<C>(&mut self, clock: &C) -> StartDisposition
    where
        C: Clock + ?Sized,
    {
        self.close_if_idle(clock);
        self.stopped_at = None;
        if self.warm {
            self.reuse_count += 1;
            StartDisposition::ReusedWarm
        } else {
            self.warm = true;
            self.fresh_open_count += 1;
            StartDisposition::FreshOpen
        }
    }

    /// Records when capture stopped while leaving the stream warm.
    pub fn on_stop<C>(&mut self, clock: &C)
    where
        C: Clock + ?Sized,
    {
        if self.warm {
            self.stopped_at = Some(clock.now());
        }
    }

    /// Closes the policy state if the injected time reached the timeout.
    ///
    /// Returns `true` exactly when a warm stream transitioned to closed.
    pub fn close_if_idle<C>(&mut self, clock: &C) -> bool
    where
        C: Clock + ?Sized,
    {
        let should_close = self
            .stopped_at
            .is_some_and(|stopped_at| clock.now().saturating_sub(stopped_at) >= self.idle_timeout);
        if should_close {
            self.mark_closed();
        }
        should_close
    }

    /// Marks the underlying stream unavailable, for example after a device error.
    pub fn mark_closed(&mut self) {
        self.warm = false;
        self.stopped_at = None;
    }

    /// Reports whether the policy currently represents an open warm stream.
    pub fn is_warm(&self) -> bool {
        self.warm
    }

    /// Returns how many starts reused a warm stream.
    pub fn reuse_count(&self) -> u64 {
        self.reuse_count
    }

    /// Returns how many starts required a fresh open.
    pub fn fresh_open_count(&self) -> u64 {
        self.fresh_open_count
    }
}
