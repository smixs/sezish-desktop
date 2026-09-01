use crate::{chunker, stream::StreamTake, CtcDecoder, Vocab, VocabError};
use ort::{session::Session, value::Tensor};
use sez_core::{SezError, Transcriber};
use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, MutexGuard, PoisonError,
    },
};
use thiserror::Error;
use tokio::runtime::Handle;

const PREPROCESSOR: &[u8] = include_bytes!("../resources/gigaam_v3_conv.onnx");
const WARMUP_SAMPLES: usize = 8_000;

/// How far the streamed take may fall short of the recording the microphone returned before it
/// is thrown away. The stream and the recording are resampled separately, so their lengths
/// differ by the filter delay and a partial block; 0.25 s covers that and nothing a listener
/// would notice missing.
const STREAM_COVERAGE_SLACK: usize = 4_000;

/// Failures returned by the local transcription adapter.
#[derive(Debug, Error)]
pub enum LocalTranscriberError {
    /// ONNX Runtime failed to initialize, load a model, or run inference.
    #[error(transparent)]
    Ort(#[from] ort::Error),
    /// The bundled token table could not be parsed.
    #[error(transparent)]
    Vocab(#[from] VocabError),
    /// A model did not return an output required by the two-stage pipeline.
    #[error("local model did not return {0}")]
    MissingOutput(&'static str),
    /// The acoustic output was not a valid `[1, time, vocab]` tensor.
    #[error("unexpected local model output: {0}")]
    UnexpectedOutput(String),
    /// A previous panic poisoned the inference lock.
    #[error("local inference lock was poisoned")]
    LockPoisoned,
}

impl From<LocalTranscriberError> for SezError {
    fn from(error: LocalTranscriberError) -> Self {
        Self::Other(error.to_string())
    }
}

struct Sessions {
    preprocessor: Session,
    acoustic_model: Session,
}

struct Inner {
    sessions: Mutex<Sessions>,
    vocab: Vocab,
    /// Filled by [`LocalTranscriber::feed`] from the capture thread, emptied by the drain.
    /// Appending is all that happens under this lock: waiting for inference there would stop
    /// the capture ring from being drained and cost the recording its samples.
    inbox: Mutex<Vec<i16>>,
    /// The dictation being recorded right now. The lock is held for the whole drain, which is
    /// what keeps the chunks in the order they were spoken.
    take: Mutex<StreamTake<LocalTranscriberError>>,
    /// One drain in flight at a time: samples arrive every few milliseconds, a chunk takes
    /// seconds, and a task per block would pile up behind the take lock.
    draining: AtomicBool,
}

/// Two-stage ONNX Runtime local transcription adapter.
#[derive(Clone)]
pub struct LocalTranscriber {
    inner: Arc<Inner>,
    runtime: Handle,
}

impl LocalTranscriber {
    /// Loads the embedded preprocessor and the downloaded acoustic model.
    ///
    /// # Panics
    ///
    /// Panics when called outside a Tokio runtime. The captured runtime handle
    /// is required for the synchronous, fire-and-forget [`Transcriber::warmup`].
    pub fn new(model_path: impl AsRef<Path>) -> Result<Self, LocalTranscriberError> {
        let runtime = Handle::current();
        ort::init().commit()?;
        let preprocessor = Session::builder()?.commit_from_memory(PREPROCESSOR)?;
        let acoustic_model = Session::builder()?.commit_from_file(model_path)?;

        Ok(Self {
            inner: Arc::new(Inner {
                sessions: Mutex::new(Sessions {
                    preprocessor,
                    acoustic_model,
                }),
                vocab: Vocab::bundled()?,
                inbox: Mutex::new(Vec::new()),
                take: Mutex::new(StreamTake::new()),
                draining: AtomicBool::new(false),
            }),
            runtime,
        })
    }

    /// Hands the recording to the model as it is captured. Runs on the thread that drains the
    /// capture ring, so it only appends: the chunks are transcribed on the blocking pool.
    pub fn feed(&self, samples: &[i16]) {
        if samples.is_empty() {
            return;
        }
        lock(&self.inner.inbox).extend_from_slice(samples);
        self.schedule_drain();
    }

    /// Opens a take. Whatever the previous one left is dropped here, so a dictation the user
    /// cancelled cannot leak its words into the next one.
    fn start_stream(&self) {
        lock(&self.inner.inbox).clear();
        lock(&self.inner.take).start();
    }

    fn schedule_drain(&self) {
        if self.inner.draining.swap(true, Ordering::AcqRel) {
            return;
        }
        let transcriber = self.clone();
        self.runtime.spawn_blocking(move || {
            transcriber.drain_ready_chunks();
            transcriber.inner.draining.store(false, Ordering::Release);
        });
    }

    /// Transcribes every chunk the take has completed so far. The inbox is picked up again
    /// after each pass, because a chunk takes seconds and the microphone keeps recording.
    fn drain_ready_chunks(&self) {
        let mut take = lock(&self.inner.take);
        while take.is_open() {
            let queued = std::mem::take(&mut *lock(&self.inner.inbox));
            if queued.is_empty() {
                return;
            }
            take.append(&waveform(&queued));
            take.transcribe_ready(|chunk| self.run_locked(chunk));
        }
    }

    /// The transcript of the take that just ended, or `None` when the stream cannot answer for
    /// it and the caller has to run the whole recording through the batch path.
    fn finish_stream(&self, recorded: usize) -> Result<Option<String>, LocalTranscriberError> {
        let mut take = lock(&self.inner.take);
        if !take.is_open() {
            return Ok(None);
        }
        let queued = std::mem::take(&mut *lock(&self.inner.inbox));
        take.append(&waveform(&queued));

        // The stream is only trusted when it saw the whole take. A microphone that was never
        // tapped, or one whose stream broke halfway, must not silently swallow the middle of a
        // dictation: the caller still has every sample and can transcribe them all.
        if take.fed() + STREAM_COVERAGE_SLACK < recorded {
            take.discard();
            return Ok(None);
        }

        take.finish(|chunk| self.run_locked(chunk)).map(Some)
    }

    fn run_locked(&self, waveform: &[f32]) -> Result<String, LocalTranscriberError> {
        let mut sessions = self
            .inner
            .sessions
            .lock()
            .map_err(|_| LocalTranscriberError::LockPoisoned)?;
        Self::run(&mut sessions, &self.inner.vocab, waveform)
    }

    /// Transcribes PCM16 mono 16 kHz samples through the local model pipeline.
    pub async fn transcribe(&self, samples: &[i16]) -> Result<String, LocalTranscriberError> {
        self.transcribe_sync(samples)
    }

    fn transcribe_sync(&self, samples: &[i16]) -> Result<String, LocalTranscriberError> {
        if samples.is_empty() {
            return Ok(String::new());
        }

        let waveform = waveform(samples);

        let mut sessions = self
            .inner
            .sessions
            .lock()
            .map_err(|_| LocalTranscriberError::LockPoisoned)?;

        // One buffer past the length the model was trained on comes back as mush, so long
        // audio is cut at silences and run piece by piece. A failing piece fails the take:
        // half a transcript is worse than an error the caller can retry.
        let mut parts = Vec::new();
        for chunk in chunker::split(&waveform) {
            let text = Self::run(&mut sessions, &self.inner.vocab, &waveform[chunk])?;
            if !text.is_empty() {
                parts.push(text);
            }
        }
        Ok(parts.join(" "))
    }

    /// One pass through the ONNX pipeline. The caller guarantees the buffer fits the model.
    fn run(
        sessions: &mut Sessions,
        vocab: &Vocab,
        waveform: &[f32],
    ) -> Result<String, LocalTranscriberError> {
        let sample_count = waveform.len();
        let waveforms = Tensor::from_array(([1_usize, sample_count], waveform.to_vec()))?;
        let waveform_lengths = Tensor::from_array((
            [1_usize],
            vec![i64::try_from(sample_count).map_err(|_| {
                LocalTranscriberError::UnexpectedOutput("sample count overflow".to_owned())
            })?],
        ))?;

        let Sessions {
            preprocessor,
            acoustic_model,
        } = sessions;
        let preprocessed = preprocessor.run(ort::inputs![
            "waveforms" => waveforms,
            "waveforms_lens" => waveform_lengths,
        ])?;
        let features = preprocessed
            .get("features")
            .ok_or(LocalTranscriberError::MissingOutput("features"))?;
        let feature_lengths = preprocessed
            .get("features_lens")
            .ok_or(LocalTranscriberError::MissingOutput("features_lens"))?;

        let acoustic = acoustic_model.run(ort::inputs![
            "features" => features,
            "feature_lengths" => feature_lengths,
        ])?;
        let log_probs = acoustic
            .get("log_probs")
            .ok_or(LocalTranscriberError::MissingOutput("log_probs"))?;
        let (shape, flat) = log_probs.try_extract_tensor::<f32>()?;
        if shape.len() != 3 {
            return Err(LocalTranscriberError::UnexpectedOutput(format!(
                "log_probs shape {shape}"
            )));
        }
        let time_steps = usize::try_from(shape[1]).map_err(|_| {
            LocalTranscriberError::UnexpectedOutput(format!("log_probs shape {shape}"))
        })?;
        let vocab_size = usize::try_from(shape[2]).map_err(|_| {
            LocalTranscriberError::UnexpectedOutput(format!("log_probs shape {shape}"))
        })?;
        let required = time_steps.checked_mul(vocab_size).ok_or_else(|| {
            LocalTranscriberError::UnexpectedOutput(format!("log_probs shape {shape}"))
        })?;
        if flat.len() < required {
            return Err(LocalTranscriberError::UnexpectedOutput(format!(
                "log_probs data {}",
                flat.len()
            )));
        }

        let frames = flat[..required]
            .chunks_exact(vocab_size)
            .map(<[f32]>::to_vec)
            .collect::<Vec<_>>();
        Ok(CtcDecoder::decode(&frames, &vocab.tokens, vocab.blank_id))
    }
}

/// PCM16 as the model wants it, normalized to `[-1, 1]`.
fn waveform(samples: &[i16]) -> Vec<f32> {
    samples
        .iter()
        .map(|&sample| f32::from(sample) / 32_768.0)
        .collect()
}

/// A panic inside inference poisons the take and inbox locks, but leaves plain buffers behind
/// them: a dictation is worth more than the poison flag, so the guard is recovered.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[async_trait::async_trait]
impl Transcriber for LocalTranscriber {
    fn warmup(&self) {
        // The coordinator calls this once per dictation, right after the microphone starts, so
        // this is where the take opens: samples fed from now on belong to it.
        self.start_stream();
        let transcriber = self.clone();
        self.runtime.spawn(async move {
            let silence = vec![0_i16; WARMUP_SAMPLES];
            let _ = transcriber.transcribe(&silence).await;
        });
    }

    async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError> {
        // A tapped microphone has already run everything but the tail through the model while
        // the user was speaking. Without the tap, or when the stream fell short of the
        // recording, this is the whole take in one go, as it was before streaming.
        if let Some(text) = self.finish_stream(samples.len())? {
            return Ok(text);
        }
        LocalTranscriber::transcribe(self, samples)
            .await
            .map_err(Into::into)
    }
}
