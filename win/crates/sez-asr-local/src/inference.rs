use crate::{chunker, CtcDecoder, Vocab, VocabError};
use ort::{session::Session, value::Tensor};
use sez_core::{SezError, Transcriber};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};
use thiserror::Error;
use tokio::runtime::Handle;

const PREPROCESSOR: &[u8] = include_bytes!("../resources/gigaam_v3_conv.onnx");
const WARMUP_SAMPLES: usize = 8_000;

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
            }),
            runtime,
        })
    }

    /// Transcribes PCM16 mono 16 kHz samples through the local model pipeline.
    pub async fn transcribe(&self, samples: &[i16]) -> Result<String, LocalTranscriberError> {
        self.transcribe_sync(samples)
    }

    fn transcribe_sync(&self, samples: &[i16]) -> Result<String, LocalTranscriberError> {
        if samples.is_empty() {
            return Ok(String::new());
        }

        let waveform = samples
            .iter()
            .map(|&sample| f32::from(sample) / 32_768.0)
            .collect::<Vec<_>>();

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

#[async_trait::async_trait]
impl Transcriber for LocalTranscriber {
    fn warmup(&self) {
        let transcriber = self.clone();
        self.runtime.spawn(async move {
            let silence = vec![0_i16; WARMUP_SAMPLES];
            let _ = transcriber.transcribe(&silence).await;
        });
    }

    async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError> {
        LocalTranscriber::transcribe(self, samples)
            .await
            .map_err(Into::into)
    }
}
