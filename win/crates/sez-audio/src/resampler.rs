use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Resampler};
use thiserror::Error;

/// Output sample rate required by `sez_core::Mic`.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Error returned while constructing or running the mono resampler.
#[derive(Debug, Error)]
pub enum ResampleError {
    /// The source rate cannot describe audio.
    #[error("source sample rate must be greater than zero")]
    InvalidSourceRate,
    /// Rubato rejected the fixed-rate resampler configuration.
    #[error("failed to construct resampler: {0}")]
    Construction(#[from] rubato::ResamplerConstructionError),
    /// The input slice could not be represented as one interleaved channel.
    #[error("invalid mono input buffer: {0}")]
    InvalidInput(String),
    /// Rubato could not process the supplied samples.
    #[error("resampling failed: {0}")]
    Processing(#[from] rubato::ResampleError),
}

/// High-quality fixed-rate mono resampler targeting 16 kHz.
pub struct MonoResampler {
    source_rate: u32,
    inner: Fft<f32>,
}

impl MonoResampler {
    /// Constructs a reusable mono resampler for `source_rate`.
    pub fn new(source_rate: u32) -> Result<Self, ResampleError> {
        if source_rate == 0 {
            return Err(ResampleError::InvalidSourceRate);
        }
        let inner = Fft::<f32>::new(
            source_rate as usize,
            TARGET_SAMPLE_RATE as usize,
            1_024,
            1,
            FixedSync::Both,
        )?;
        Ok(Self { source_rate, inner })
    }

    /// Resamples one complete mono clip, trimming filter delay and preserving its duration.
    pub fn process(&mut self, input: &[f32]) -> Result<Vec<f32>, ResampleError> {
        if input.is_empty() {
            return Ok(Vec::new());
        }
        if self.source_rate == TARGET_SAMPLE_RATE {
            return Ok(input.to_vec());
        }

        let adapter = InterleavedSlice::new(input, 1, input.len())
            .map_err(|error| ResampleError::InvalidInput(error.to_string()))?;
        let output = self.inner.process_all(&adapter, input.len(), None)?;
        Ok(output.take_data())
    }
}
