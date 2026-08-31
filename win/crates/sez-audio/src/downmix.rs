use crate::RingProducer;
use thiserror::Error;

/// Error returned by interleaved downmixing.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum DownmixError {
    /// Interleaved audio must declare at least one channel.
    #[error("channel count must be greater than zero")]
    ZeroChannels,
}

/// Observable result of one downmix-and-push call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DownmixStats {
    /// Number of complete interleaved frames visited.
    pub frames: usize,
    /// Number of resulting mono samples dropped because the ring was full.
    pub dropped: usize,
}

/// Averages each complete interleaved `f32` frame and pushes it into the ring.
///
/// The function performs no allocation, locking, formatting, or boxing and is
/// suitable for the CPAL realtime data callback.
#[inline]
pub fn push_interleaved_f32(
    producer: &mut RingProducer,
    interleaved: &[f32],
    channels: usize,
) -> Result<DownmixStats, DownmixError> {
    push_interleaved_converted(producer, interleaved, channels, |sample| sample)
}

#[inline]
pub(crate) fn push_interleaved_converted<T, F>(
    producer: &mut RingProducer,
    interleaved: &[T],
    channels: usize,
    mut to_f32: F,
) -> Result<DownmixStats, DownmixError>
where
    T: Copy,
    F: FnMut(T) -> f32,
{
    if channels == 0 {
        return Err(DownmixError::ZeroChannels);
    }

    let mut dropped = 0;
    let mut frames = 0;
    for frame in interleaved.chunks_exact(channels) {
        let sum = frame
            .iter()
            .copied()
            .fold(0.0_f32, |sum, sample| sum + to_f32(sample));
        let mono = sum / channels as f32;
        dropped += usize::from(!producer.push(mono));
        frames += 1;
    }

    Ok(DownmixStats { frames, dropped })
}
