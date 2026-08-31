use sez_core::Clock;
use std::time::Duration;

pub struct ModelIdlePolicy {
    idle_timeout: Duration,
    idle_since: Option<Duration>,
    loaded: bool,
}

impl ModelIdlePolicy {
    pub fn new(idle_timeout: Duration) -> Self {
        Self {
            idle_timeout,
            idle_since: None,
            loaded: false,
        }
    }

    pub fn on_loaded(&mut self) {
        self.loaded = true;
        self.idle_since = None;
    }

    pub fn on_active(&mut self) {
        self.idle_since = None;
    }

    pub fn on_idle<C>(&mut self, clock: &C)
    where
        C: Clock + ?Sized,
    {
        if self.loaded {
            self.idle_since = Some(clock.now());
        }
    }

    pub fn unload_if_idle<C>(&mut self, clock: &C) -> bool
    where
        C: Clock + ?Sized,
    {
        let should_unload = self.loaded
            && self.idle_since.is_some_and(|idle_since| {
                clock.now().saturating_sub(idle_since) >= self.idle_timeout
            });
        if should_unload {
            self.loaded = false;
            self.idle_since = None;
        }
        should_unload
    }

    pub fn mark_unloaded(&mut self) {
        self.loaded = false;
        self.idle_since = None;
    }

    #[cfg(test)]
    pub fn is_loaded(&self) -> bool {
        self.loaded
    }
}

#[cfg(test)]
mod tests {
    use super::ModelIdlePolicy;
    use sez_core::test_util::MockClock;
    use std::time::Duration;

    #[test]
    fn loaded_local_model_unloads_once_after_the_injected_idle_deadline() {
        let clock = MockClock::new(Duration::from_secs(10));
        let mut policy = ModelIdlePolicy::new(Duration::from_secs(30));
        policy.on_loaded();
        policy.on_idle(&clock);

        clock.advance(Duration::from_secs(29));
        assert!(!policy.unload_if_idle(&clock));
        assert!(policy.is_loaded());

        clock.advance(Duration::from_secs(1));
        assert!(policy.unload_if_idle(&clock));
        assert!(!policy.is_loaded());
        assert!(!policy.unload_if_idle(&clock));
    }
}
