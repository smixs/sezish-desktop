//! Cross-platform microphone capture for the Windows port.

mod downmix;
mod mic;
mod pcm;
mod policy;
mod resampler;
mod ring;

pub use downmix::{push_interleaved_f32, DownmixError, DownmixStats};
pub use mic::{CpalMic, DEFAULT_IDLE_TIMEOUT};
pub use pcm::f32_to_i16;
pub use policy::{IdleClosePolicy, StartDisposition};
pub use resampler::{MonoResampler, ResampleError, TARGET_SAMPLE_RATE};
pub use ring::{RingBufferError, RingConsumer, RingProducer, SpscRingBuffer};
