use sez_audio::{IdleClosePolicy, StartDisposition};
use sez_core::test_util::MockClock;
use std::time::Duration;

#[test]
fn warm_stream_reuses_before_timeout_and_closes_after_timeout() {
    let clock = MockClock::new(Duration::ZERO);
    let mut policy = IdleClosePolicy::new(Duration::from_secs(30));

    assert_eq!(
        policy.on_start(&clock),
        StartDisposition::FreshOpen,
        "first start must open a stream"
    );
    policy.on_stop(&clock);
    clock.advance(Duration::from_secs(29));

    assert!(!policy.close_if_idle(&clock));
    assert!(policy.is_warm());
    assert_eq!(
        policy.on_start(&clock),
        StartDisposition::ReusedWarm,
        "a start before timeout must reuse the warm stream"
    );
    assert_eq!(policy.reuse_count(), 1);
    assert_eq!(policy.fresh_open_count(), 1);

    policy.on_stop(&clock);
    clock.advance(Duration::from_secs(30));

    assert!(policy.close_if_idle(&clock));
    assert!(!policy.is_warm());
    assert_eq!(policy.on_start(&clock), StartDisposition::FreshOpen);
    assert_eq!(policy.fresh_open_count(), 2);
}
