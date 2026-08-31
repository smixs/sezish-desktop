use async_trait::async_trait;
use std::time::Duration;
use thiserror::Error;

pub mod wav;

/// Errors shared by the frozen adapter seams.
#[non_exhaustive]
#[derive(Debug, Error)]
pub enum SezError {
    /// An adapter encountered an I/O failure.
    #[error(transparent)]
    Io(#[from] std::io::Error),
    /// An adapter operation exceeded its deadline.
    #[error("operation timed out")]
    Timeout,
    /// An adapter failed for a reason not yet represented by this scaffold.
    #[error("{0}")]
    Other(String),
}

/// One dictation returned by [`History`].
///
/// Audio is persisted by the adapter (one WAV per dictation on disk) and is
/// deliberately NOT part of this value: the UI surface only ever needs the
/// text; the audio files are reached through the history folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryEntry {
    /// Recognized text. Empty text is a valid history value.
    pub text: String,
    /// Wall-clock moment the dictation was recorded (display only — never
    /// used in coordinator logic, which runs on the injected [`Clock`]).
    pub recorded_at: std::time::SystemTime,
}

/// Microphone capture seam.
///
/// This trait is part of the frozen seam per ADR-0002. Changes require a
/// dedicated orchestrator PR.
#[async_trait]
pub trait Mic: Send {
    /// Starts capturing PCM16 mono audio.
    async fn start(&mut self) -> Result<(), SezError>;

    /// Stops capture and returns the captured samples.
    async fn stop(&mut self) -> Result<Vec<i16>, SezError>;
}

/// Audio transcription seam.
///
/// This trait is part of the frozen seam per ADR-0002. Changes require a
/// dedicated orchestrator PR.
#[async_trait]
pub trait Transcriber: Send + Sync {
    /// Best-effort latency pre-payment, fired at recording start: the cloud
    /// path opens a keep-alive TLS connection, the local path runs silence
    /// through the model. Fire-and-forget: implementations MUST return
    /// immediately, spawning any real work on their own runtime, and swallow
    /// failures — a sequential await here would make short hold dictations
    /// wait out the warmup before `end()` can run.
    fn warmup(&self);

    /// Transcribes PCM16 mono samples into text.
    async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError>;
}

/// Focused-application insertion seam.
///
/// This trait is part of the frozen seam per ADR-0002. Changes require a
/// dedicated orchestrator PR.
#[async_trait]
pub trait Inserter: Send + Sync {
    /// Inserts text using clipboard replacement and one batched paste chord.
    async fn insert(&self, text: &str) -> Result<(), SezError>;
}

/// Dictation history seam.
///
/// This trait is part of the frozen seam per ADR-0002. Changes require a
/// dedicated orchestrator PR.
#[async_trait]
pub trait History: Send + Sync {
    /// Adds a dictation to the bounded FIFO.
    async fn record(&mut self, text: &str, audio: &[i16]) -> Result<(), SezError>;

    /// Returns recent dictations in newest-first order.
    async fn recent(&self) -> Result<Vec<HistoryEntry>, SezError>;
}

/// Injectable time seam for coordinator logic.
///
/// This trait is part of the frozen seam per ADR-0002. Changes require a
/// dedicated orchestrator PR.
pub trait Clock: Send + Sync {
    /// Returns deterministic time elapsed from an implementation-defined epoch.
    fn now(&self) -> Duration;
}

/// Observable phase of one dictation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// Ready to begin a dictation.
    Idle,
    /// Capturing microphone samples.
    Recording,
    /// Finishing a captured dictation.
    Processing,
}

/// Result of finishing one dictation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// No dictation was active, or the captured audio was too short.
    Ignored,
    /// The transcript was recorded in history and inserted.
    Inserted,
    /// History was recorded, but insertion failed.
    InsertFailed(String),
    /// Transcription failed or returned empty text; history kept the audio.
    NoText,
    /// Microphone capture failed, so there was no audio to keep.
    Failed,
}

/// Drives one dictation through Idle → Recording → Processing → Idle.
pub struct Coordinator<M, T, I, H> {
    state: State,
    mic: M,
    transcriber: T,
    inserter: I,
    history: H,
}

impl<M, T, I, H> Coordinator<M, T, I, H>
where
    M: Mic,
    T: Transcriber,
    I: Inserter,
    H: History,
{
    /// Microphone sample rate expected by the coordinator.
    pub const SAMPLE_RATE: usize = 16_000;

    /// Shortest dictation retained: 0.3 seconds at 16 kHz.
    pub const MINIMUM_SAMPLES: usize = 4_800;

    /// Creates an idle coordinator over the injected adapter seams.
    pub fn new(mic: M, transcriber: T, inserter: I, history: H) -> Self {
        Self {
            state: State::Idle,
            mic,
            transcriber,
            inserter,
            history,
        }
    }

    /// Returns the current coordinator phase.
    pub fn state(&self) -> State {
        self.state
    }

    /// Starts microphone capture from Idle.
    pub async fn begin(&mut self) {
        if self.state != State::Idle {
            return;
        }

        if self.mic.start().await.is_err() {
            return;
        }

        self.state = State::Recording;
        self.transcriber.warmup();
    }

    /// Finishes a recording and returns its caller-facing result.
    pub async fn end(&mut self) -> Outcome {
        if self.state != State::Recording {
            return Outcome::Ignored;
        }

        self.state = State::Processing;
        let outcome = match self.mic.stop().await {
            Err(_) => Outcome::Failed,
            Ok(samples) if samples.len() < Self::MINIMUM_SAMPLES => Outcome::Ignored,
            Ok(samples) => match self.transcriber.transcribe(&samples).await {
                Ok(text) if !text.is_empty() => {
                    let _ = self.history.record(&text, &samples).await;
                    match self.inserter.insert(&text).await {
                        Ok(()) => Outcome::Inserted,
                        Err(error) => Outcome::InsertFailed(error.to_string()),
                    }
                }
                Ok(_) | Err(_) => {
                    let _ = self.history.record("", &samples).await;
                    Outcome::NoText
                }
            },
        };
        self.state = State::Idle;
        outcome
    }

    /// Stops and discards the active recording.
    pub async fn cancel(&mut self) {
        if self.state != State::Recording {
            return;
        }

        self.state = State::Processing;
        let _ = self.mic.stop().await;
        self.state = State::Idle;
    }
}

/// Test clock exported when the `test-util` feature is enabled.
#[cfg(any(test, feature = "test-util"))]
pub mod test_util {
    use super::Clock;
    use std::sync::Mutex;
    use std::time::Duration;

    /// A manually controlled clock for coordinator tests.
    pub struct MockClock {
        now: Mutex<Duration>,
    }

    impl MockClock {
        /// Creates a clock at `now`.
        pub fn new(now: Duration) -> Self {
            Self {
                now: Mutex::new(now),
            }
        }

        /// Replaces the current fake time.
        pub fn set(&self, now: Duration) {
            *self.now.lock().expect("mock clock mutex poisoned") = now;
        }

        /// Advances the current fake time.
        pub fn advance(&self, delta: Duration) {
            let mut now = self.now.lock().expect("mock clock mutex poisoned");
            *now += delta;
        }
    }

    impl Clock for MockClock {
        fn now(&self) -> Duration {
            *self.now.lock().expect("mock clock mutex poisoned")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        test_util::MockClock, Clock, Coordinator, History, HistoryEntry, Inserter, Mic, Outcome,
        SezError, State, Transcriber,
    };
    use async_trait::async_trait;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    type EventLog = Arc<Mutex<Vec<&'static str>>>;

    struct MockMic {
        calls: Arc<Mutex<MicCalls>>,
        events: EventLog,
    }

    struct MicCalls {
        start_count: usize,
        stop_count: usize,
        start_result: Option<Result<(), SezError>>,
        stop_result: Option<Result<Vec<i16>, SezError>>,
    }

    #[async_trait]
    impl Mic for MockMic {
        async fn start(&mut self) -> Result<(), SezError> {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .push("mic.start");
            let mut calls = self.calls.lock().expect("mic calls mutex poisoned");
            calls.start_count += 1;
            calls.start_result.take().unwrap_or(Ok(()))
        }

        async fn stop(&mut self) -> Result<Vec<i16>, SezError> {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .push("mic.stop");
            let mut calls = self.calls.lock().expect("mic calls mutex poisoned");
            calls.stop_count += 1;
            calls.stop_result.take().unwrap_or_else(|| Ok(Vec::new()))
        }
    }

    struct MockTranscriber {
        calls: Arc<Mutex<TranscriberCalls>>,
        events: EventLog,
    }

    struct TranscriberCalls {
        warmup_count: usize,
        transcribe_count: usize,
        transcribe_samples: Vec<Vec<i16>>,
        transcribe_result: Option<Result<String, SezError>>,
    }

    #[async_trait]
    impl Transcriber for MockTranscriber {
        fn warmup(&self) {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .push("transcriber.warmup");
            self.calls
                .lock()
                .expect("transcriber calls mutex poisoned")
                .warmup_count += 1;
        }

        async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError> {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .push("transcriber.transcribe");
            let mut calls = self.calls.lock().expect("transcriber calls mutex poisoned");
            calls.transcribe_count += 1;
            calls.transcribe_samples.push(samples.to_vec());
            calls
                .transcribe_result
                .take()
                .unwrap_or_else(|| Ok(String::new()))
        }
    }

    struct MockInserter {
        calls: Arc<Mutex<InserterCalls>>,
        events: EventLog,
    }

    struct InserterCalls {
        insert_count: usize,
        inserted_texts: Vec<String>,
        insert_result: Option<Result<(), SezError>>,
    }

    #[async_trait]
    impl Inserter for MockInserter {
        async fn insert(&self, text: &str) -> Result<(), SezError> {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .push("inserter.insert");
            let mut calls = self.calls.lock().expect("inserter calls mutex poisoned");
            calls.insert_count += 1;
            calls.inserted_texts.push(text.to_owned());
            calls.insert_result.take().unwrap_or(Ok(()))
        }
    }

    struct MockHistory {
        calls: Arc<Mutex<HistoryCalls>>,
        events: EventLog,
    }

    struct HistoryCalls {
        record_count: usize,
        record_arguments: Vec<(String, Vec<i16>)>,
        record_result: Option<Result<(), SezError>>,
        recent_count: usize,
        recent_result: Option<Result<Vec<HistoryEntry>, SezError>>,
    }

    #[async_trait]
    impl History for MockHistory {
        async fn record(&mut self, text: &str, audio: &[i16]) -> Result<(), SezError> {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .push("history.record");
            let mut calls = self.calls.lock().expect("history calls mutex poisoned");
            calls.record_count += 1;
            calls
                .record_arguments
                .push((text.to_owned(), audio.to_vec()));
            calls.record_result.take().unwrap_or(Ok(()))
        }

        async fn recent(&self) -> Result<Vec<HistoryEntry>, SezError> {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .push("history.recent");
            let mut calls = self.calls.lock().expect("history calls mutex poisoned");
            calls.recent_count += 1;
            calls.recent_result.take().unwrap_or_else(|| Ok(Vec::new()))
        }
    }

    struct Rig {
        coordinator: Coordinator<MockMic, MockTranscriber, MockInserter, MockHistory>,
        mic: Arc<Mutex<MicCalls>>,
        transcriber: Arc<Mutex<TranscriberCalls>>,
        inserter: Arc<Mutex<InserterCalls>>,
        history: Arc<Mutex<HistoryCalls>>,
        events: EventLog,
    }

    impl Rig {
        fn new(samples: Vec<i16>, transcription: Result<String, SezError>) -> Self {
            let events = Arc::new(Mutex::new(Vec::new()));
            let mic = Arc::new(Mutex::new(MicCalls {
                start_count: 0,
                stop_count: 0,
                start_result: Some(Ok(())),
                stop_result: Some(Ok(samples)),
            }));
            let transcriber = Arc::new(Mutex::new(TranscriberCalls {
                warmup_count: 0,
                transcribe_count: 0,
                transcribe_samples: Vec::new(),
                transcribe_result: Some(transcription),
            }));
            let inserter = Arc::new(Mutex::new(InserterCalls {
                insert_count: 0,
                inserted_texts: Vec::new(),
                insert_result: Some(Ok(())),
            }));
            let history = Arc::new(Mutex::new(HistoryCalls {
                record_count: 0,
                record_arguments: Vec::new(),
                record_result: Some(Ok(())),
                recent_count: 0,
                recent_result: Some(Ok(Vec::new())),
            }));

            let coordinator = Coordinator::new(
                MockMic {
                    calls: Arc::clone(&mic),
                    events: Arc::clone(&events),
                },
                MockTranscriber {
                    calls: Arc::clone(&transcriber),
                    events: Arc::clone(&events),
                },
                MockInserter {
                    calls: Arc::clone(&inserter),
                    events: Arc::clone(&events),
                },
                MockHistory {
                    calls: Arc::clone(&history),
                    events: Arc::clone(&events),
                },
            );

            Self {
                coordinator,
                mic,
                transcriber,
                inserter,
                history,
                events,
            }
        }

        fn clear_events(&self) {
            self.events
                .lock()
                .expect("event log mutex poisoned")
                .clear();
        }

        fn assert_no_calls(&self) {
            let mic = self.mic.lock().expect("mic calls mutex poisoned");
            assert_eq!(mic.start_count, 0);
            assert_eq!(mic.stop_count, 0);
            drop(mic);

            let transcriber = self
                .transcriber
                .lock()
                .expect("transcriber calls mutex poisoned");
            assert_eq!(transcriber.warmup_count, 0);
            assert_eq!(transcriber.transcribe_count, 0);
            drop(transcriber);

            let inserter = self.inserter.lock().expect("inserter calls mutex poisoned");
            assert_eq!(inserter.insert_count, 0);
            drop(inserter);

            let history = self.history.lock().expect("history calls mutex poisoned");
            assert_eq!(history.record_count, 0);
            assert_eq!(history.recent_count, 0);
            drop(history);

            assert!(self
                .events
                .lock()
                .expect("event log mutex poisoned")
                .is_empty());
        }
    }

    #[test]
    fn clock_seam_accepts_a_controllable_mock() {
        let clock = MockClock::new(Duration::from_secs(40));
        clock.advance(Duration::from_secs(2));
        assert_eq!(clock.now(), Duration::from_secs(42));
    }

    #[test]
    fn coordinator_constants_match_the_macos_reference() {
        assert_eq!(
            Coordinator::<MockMic, MockTranscriber, MockInserter, MockHistory>::SAMPLE_RATE,
            16_000
        );
        assert_eq!(
            Coordinator::<MockMic, MockTranscriber, MockInserter, MockHistory>::MINIMUM_SAMPLES,
            4_800
        );
    }

    #[tokio::test]
    async fn begin_is_rejected_while_recording_or_processing_without_side_effects() {
        for state in [State::Recording, State::Processing] {
            let mut rig = Rig::new(vec![1; 4_800], Ok("salom".to_owned()));
            rig.coordinator.state = state;

            rig.coordinator.begin().await;

            assert_eq!(rig.coordinator.state(), state);
            rig.assert_no_calls();
        }
    }

    #[tokio::test]
    async fn end_is_ignored_outside_recording_without_side_effects() {
        for state in [State::Idle, State::Processing] {
            let mut rig = Rig::new(vec![1; 4_800], Ok("salom".to_owned()));
            rig.coordinator.state = state;

            let outcome = rig.coordinator.end().await;

            assert_eq!(outcome, Outcome::Ignored);
            assert_eq!(rig.coordinator.state(), state);
            rig.assert_no_calls();
        }
    }

    #[tokio::test]
    async fn dictation_shorter_than_4800_samples_is_ignored_without_transcription_or_storage() {
        let mut rig = Rig::new(vec![1; 4_799], Ok("salom".to_owned()));
        rig.coordinator.begin().await;
        rig.clear_events();

        let outcome = rig.coordinator.end().await;

        assert_eq!(outcome, Outcome::Ignored);
        assert_eq!(rig.coordinator.state(), State::Idle);
        assert_eq!(
            rig.events
                .lock()
                .expect("event log mutex poisoned")
                .as_slice(),
            ["mic.stop"]
        );
        assert_eq!(
            rig.transcriber
                .lock()
                .expect("transcriber calls mutex poisoned")
                .transcribe_count,
            0
        );
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_count,
            0
        );
        assert_eq!(
            rig.inserter
                .lock()
                .expect("inserter calls mutex poisoned")
                .insert_count,
            0
        );
    }

    #[tokio::test]
    async fn empty_transcript_keeps_captured_audio_in_history_with_empty_text() {
        let samples = vec![7; 4_800];
        let mut rig = Rig::new(samples.clone(), Ok(String::new()));
        rig.coordinator.begin().await;

        let outcome = rig.coordinator.end().await;

        assert_eq!(outcome, Outcome::NoText);
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_arguments,
            vec![(String::new(), samples.clone())]
        );
        assert_eq!(
            rig.transcriber
                .lock()
                .expect("transcriber calls mutex poisoned")
                .transcribe_samples,
            vec![samples]
        );
        assert_eq!(
            rig.inserter
                .lock()
                .expect("inserter calls mutex poisoned")
                .insert_count,
            0
        );
    }

    #[tokio::test]
    async fn transcription_error_keeps_captured_audio_in_history_with_empty_text() {
        let samples = vec![8; 4_800];
        let mut rig = Rig::new(
            samples.clone(),
            Err(SezError::Other("transcription failed".to_owned())),
        );
        rig.coordinator.begin().await;

        let outcome = rig.coordinator.end().await;

        assert_eq!(outcome, Outcome::NoText);
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_arguments,
            vec![(String::new(), samples)]
        );
        assert_eq!(
            rig.inserter
                .lock()
                .expect("inserter calls mutex poisoned")
                .insert_count,
            0
        );
    }

    #[tokio::test]
    async fn history_is_recorded_before_insert_and_survives_insert_failure() {
        let samples = vec![9; 4_800];
        let mut rig = Rig::new(samples.clone(), Ok("salom".to_owned()));
        rig.inserter
            .lock()
            .expect("inserter calls mutex poisoned")
            .insert_result = Some(Err(SezError::Other("secure input".to_owned())));
        rig.coordinator.begin().await;
        rig.clear_events();

        let outcome = rig.coordinator.end().await;

        assert_eq!(outcome, Outcome::InsertFailed("secure input".to_owned()));
        assert_eq!(
            rig.events
                .lock()
                .expect("event log mutex poisoned")
                .as_slice(),
            [
                "mic.stop",
                "transcriber.transcribe",
                "history.record",
                "inserter.insert"
            ]
        );
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_arguments,
            vec![("salom".to_owned(), samples)]
        );
        assert_eq!(
            rig.inserter
                .lock()
                .expect("inserter calls mutex poisoned")
                .inserted_texts,
            vec!["salom".to_owned()]
        );
    }

    #[tokio::test]
    async fn successful_dictation_is_recorded_then_inserted() {
        let samples = vec![10; 4_800];
        let mut rig = Rig::new(samples.clone(), Ok("matn".to_owned()));
        rig.coordinator.begin().await;
        rig.clear_events();

        let outcome = rig.coordinator.end().await;

        assert_eq!(outcome, Outcome::Inserted);
        assert_eq!(rig.coordinator.state(), State::Idle);
        assert_eq!(
            rig.events
                .lock()
                .expect("event log mutex poisoned")
                .as_slice(),
            [
                "mic.stop",
                "transcriber.transcribe",
                "history.record",
                "inserter.insert"
            ]
        );
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_arguments,
            vec![("matn".to_owned(), samples)]
        );
    }

    #[tokio::test]
    async fn mic_start_error_returns_to_idle_without_downstream_side_effects() {
        let mut rig = Rig::new(vec![1; 4_800], Ok("salom".to_owned()));
        rig.mic
            .lock()
            .expect("mic calls mutex poisoned")
            .start_result = Some(Err(SezError::Other("microphone denied".to_owned())));

        rig.coordinator.begin().await;

        assert_eq!(rig.coordinator.state(), State::Idle);
        assert_eq!(
            rig.mic
                .lock()
                .expect("mic calls mutex poisoned")
                .start_count,
            1
        );
        assert_eq!(
            rig.transcriber
                .lock()
                .expect("transcriber calls mutex poisoned")
                .warmup_count,
            0
        );
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_count,
            0
        );
        assert_eq!(
            rig.inserter
                .lock()
                .expect("inserter calls mutex poisoned")
                .insert_count,
            0
        );
    }

    #[tokio::test]
    async fn mic_stop_error_returns_failed_and_keeps_no_history() {
        let mut rig = Rig::new(vec![1; 4_800], Ok("salom".to_owned()));
        rig.mic
            .lock()
            .expect("mic calls mutex poisoned")
            .stop_result = Some(Err(SezError::Other("capture failed".to_owned())));
        rig.coordinator.begin().await;

        let outcome = rig.coordinator.end().await;

        assert_eq!(outcome, Outcome::Failed);
        assert_eq!(rig.coordinator.state(), State::Idle);
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_count,
            0
        );
        assert_eq!(
            rig.inserter
                .lock()
                .expect("inserter calls mutex poisoned")
                .insert_count,
            0
        );
    }

    #[tokio::test]
    async fn cancel_stops_mic_and_discards_samples_without_downstream_calls() {
        let mut rig = Rig::new(vec![11; 4_800], Ok("salom".to_owned()));
        rig.coordinator.begin().await;
        rig.clear_events();

        rig.coordinator.cancel().await;

        assert_eq!(rig.coordinator.state(), State::Idle);
        assert_eq!(
            rig.events
                .lock()
                .expect("event log mutex poisoned")
                .as_slice(),
            ["mic.stop"]
        );
        assert_eq!(
            rig.transcriber
                .lock()
                .expect("transcriber calls mutex poisoned")
                .transcribe_count,
            0
        );
        assert_eq!(
            rig.history
                .lock()
                .expect("history calls mutex poisoned")
                .record_count,
            0
        );
        assert_eq!(
            rig.inserter
                .lock()
                .expect("inserter calls mutex poisoned")
                .insert_count,
            0
        );
    }

    #[tokio::test]
    async fn cancel_is_a_no_op_outside_recording() {
        for state in [State::Idle, State::Processing] {
            let mut rig = Rig::new(vec![1; 4_800], Ok("salom".to_owned()));
            rig.coordinator.state = state;

            rig.coordinator.cancel().await;

            assert_eq!(rig.coordinator.state(), state);
            rig.assert_no_calls();
        }
    }

    #[tokio::test]
    async fn warmup_is_called_exactly_once_per_successful_begin() {
        let mut rig = Rig::new(vec![1; 4_800], Ok("salom".to_owned()));

        rig.coordinator.begin().await;
        rig.coordinator.begin().await;

        assert_eq!(
            rig.transcriber
                .lock()
                .expect("transcriber calls mutex poisoned")
                .warmup_count,
            1
        );

        rig.coordinator.cancel().await;
        rig.coordinator.begin().await;

        assert_eq!(
            rig.transcriber
                .lock()
                .expect("transcriber calls mutex poisoned")
                .warmup_count,
            2
        );
        assert_eq!(
            rig.mic
                .lock()
                .expect("mic calls mutex poisoned")
                .start_count,
            2
        );
    }
}
