use sez_audio::CpalMic;
use sez_core::{test_util::MockClock, Mic, SezError};
use std::sync::Arc;
use std::time::Duration;

#[tokio::test]
async fn device_loss_is_reported_as_typed_sez_error_without_hardware() {
    let clock = Arc::new(MockClock::new(Duration::ZERO));
    let mut mic = CpalMic::new(clock);

    mic.report_stream_error(cpal::StreamError::DeviceNotAvailable);

    match mic.stop().await.expect_err("device loss must be surfaced") {
        SezError::Other(message) => {
            assert!(message.contains("audio stream"));
            assert!(message.contains("device"));
        }
        other => panic!("expected SezError::Other, got {other:?}"),
    }
}
