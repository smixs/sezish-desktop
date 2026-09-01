use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Indexing, Resampler};
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
        Ok(Self {
            source_rate,
            inner: fft(source_rate)?,
        })
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

/// Resamples a recording to 16 kHz while it is still being captured.
///
/// [`MonoResampler`] sees a whole clip at once; this one sees it a block at a time and keeps
/// the filter state between blocks, so consecutive blocks join without a seam. The startup
/// delay is trimmed off the first output, the same as [`MonoResampler::process`] does, so both
/// render the same recording the same way.
pub struct StreamResampler {
    source_rate: u32,
    inner: Fft<f32>,
    /// Captured samples that are not a whole block yet.
    pending: Vec<f32>,
    /// Output frames of startup delay still to be discarded.
    delay: usize,
}

impl StreamResampler {
    /// Constructs a resampler for one recording captured at `source_rate`.
    pub fn new(source_rate: u32) -> Result<Self, ResampleError> {
        let inner = fft(source_rate)?;
        let delay = inner.output_delay();
        Ok(Self {
            source_rate,
            inner,
            pending: Vec::new(),
            delay,
        })
    }

    /// Everything that became ready once `input` is appended to what the last call left over.
    pub fn push(&mut self, input: &[f32]) -> Result<Vec<f32>, ResampleError> {
        if self.source_rate == TARGET_SAMPLE_RATE {
            return Ok(input.to_vec());
        }
        self.pending.extend_from_slice(input);

        let mut output = Vec::new();
        while self.pending.len() >= self.inner.input_frames_next() {
            let frames = self.inner.input_frames_next();
            let block = self.block(frames, None)?;
            self.pending.drain(..frames);
            output.extend_from_slice(&self.trimmed(block));
        }
        Ok(output)
    }

    /// The last, partial block, once the recording is over.
    pub fn flush(&mut self) -> Result<Vec<f32>, ResampleError> {
        if self.source_rate == TARGET_SAMPLE_RATE || self.pending.is_empty() {
            return Ok(Vec::new());
        }
        let frames = self.pending.len();
        // The resampler always writes a whole output block, padding the missing input with
        // silence. Only the frames the remaining input is worth are kept.
        let expected =
            (frames as f64 * f64::from(TARGET_SAMPLE_RATE) / f64::from(self.source_rate)) as usize;
        let block = self.block(frames, Some(frames))?;
        self.pending.clear();

        let mut output = self.trimmed(block);
        output.truncate(expected);
        Ok(output)
    }

    fn block(&mut self, frames: usize, partial: Option<usize>) -> Result<Vec<f32>, ResampleError> {
        let adapter = InterleavedSlice::new(&self.pending[..frames], 1, frames)
            .map_err(|error| ResampleError::InvalidInput(error.to_string()))?;
        let indexing = partial.map(|len| Indexing::new().partial_len(len));
        let output = self.inner.process(&adapter, indexing.as_ref())?;
        Ok(output.take_data())
    }

    fn trimmed(&mut self, mut block: Vec<f32>) -> Vec<f32> {
        let trim = self.delay.min(block.len());
        self.delay -= trim;
        block.drain(..trim);
        block
    }
}

fn fft(source_rate: u32) -> Result<Fft<f32>, ResampleError> {
    if source_rate == 0 {
        return Err(ResampleError::InvalidSourceRate);
    }
    Ok(Fft::<f32>::new(
        source_rate as usize,
        TARGET_SAMPLE_RATE as usize,
        1_024,
        1,
        FixedSync::Both,
    )?)
}
