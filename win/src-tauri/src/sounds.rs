//! The brand sounds (macOS `SoundPlayer.swift`): one WAV per event, played at
//! the volume from settings (percent, 0–100). `PlaySoundW` has no volume of its own, so the
//! samples are scaled in memory and played from there.

use sez_core::feedback::SoundEvent;

#[cfg_attr(not(windows), allow(dead_code))]
pub fn sound_file_name(event: SoundEvent) -> String {
    format!("{}.wav", event.resource_name())
}

#[cfg_attr(not(windows), allow(dead_code))]
/// The same WAV with every 16-bit PCM sample scaled to `percent`; None for
/// anything that is not one.
pub fn scale_pcm16_wav(bytes: &[u8], percent: u8) -> Option<Vec<u8>> {
    if bytes.len() < 12 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let mut pcm16 = false;
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let id = &bytes[at..at + 4];
        let size = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().ok()?) as usize;
        let body = at + 8;
        if id == b"fmt " {
            let fmt = bytes.get(body..body + 16)?;
            pcm16 = u16::from_le_bytes([fmt[0], fmt[1]]) == 1
                && u16::from_le_bytes([fmt[14], fmt[15]]) == 16;
        } else if id == b"data" {
            if !pcm16 {
                return None;
            }
            let end = body.checked_add(size)?.min(bytes.len());
            let mut out = bytes.to_vec();
            if percent < 100 {
                let gain = i32::from(percent);
                let (samples, _) = out[body..end].as_chunks_mut::<2>();
                for sample in samples {
                    let value = i32::from(i16::from_le_bytes(*sample));
                    *sample = ((value * gain).div_euclid(100) as i16).to_le_bytes();
                }
            }
            return Some(out);
        }
        at = body + size + (size & 1);
    }
    None
}

/// Plays `event` at `percent`, replacing whatever sound is still playing.
#[cfg(windows)]
pub fn play(event: SoundEvent, percent: u8) {
    use std::sync::Mutex;
    use windows::core::PCWSTR;
    use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT};

    // SND_MEMORY plays straight from this buffer, so it has to outlive the
    // sound: it lives here until the next one replaces it.
    static PLAYING: Mutex<Vec<u8>> = Mutex::new(Vec::new());

    let Some(bytes) = std::env::current_exe().ok().and_then(|exe| {
        std::fs::read(exe.parent()?.join("resources").join(sound_file_name(event))).ok()
    }) else {
        return;
    };
    let Some(scaled) = scale_pcm16_wav(&bytes, percent) else {
        return;
    };
    let mut playing = PLAYING
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    unsafe {
        // Stop the previous sound before its buffer goes away.
        let _ = PlaySoundW(PCWSTR::null(), None, Default::default());
        *playing = scaled;
        let _ = PlaySoundW(
            PCWSTR(playing.as_ptr().cast()),
            None,
            SND_MEMORY | SND_ASYNC | SND_NODEFAULT,
        );
    }
}

#[cfg(not(windows))]
pub fn play(_event: SoundEvent, _percent: u8) {}

#[cfg(test)]
mod tests {
    use super::{scale_pcm16_wav, sound_file_name};
    use sez_core::feedback::SoundEvent;

    fn wav(samples: &[i16], filler: bool) -> Vec<u8> {
        let mut out = Vec::new();
        let data: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        let extra = if filler { 8 + 4 } else { 0 };
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&((4 + 24 + extra + 8 + data.len()) as u32).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&[1, 0, 1, 0]);
        out.extend_from_slice(&44_100u32.to_le_bytes());
        out.extend_from_slice(&88_200u32.to_le_bytes());
        out.extend_from_slice(&[2, 0, 16, 0]);
        if filler {
            out.extend_from_slice(b"FLLR");
            out.extend_from_slice(&4u32.to_le_bytes());
            out.extend_from_slice(&[0, 0, 0, 0]);
        }
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&data);
        out
    }

    fn data_samples(bytes: &[u8]) -> Vec<i16> {
        let at = bytes.windows(4).position(|w| w == b"data").unwrap() + 8;
        bytes[at..]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| i16::from_le_bytes(*c))
            .collect()
    }

    #[test]
    fn half_volume_halves_every_sample_and_keeps_the_header() {
        let source = wav(&[1_000, -2_000, 32_767, -32_768], true);
        let scaled = scale_pcm16_wav(&source, 50).expect("valid wav");
        assert_eq!(scaled.len(), source.len());
        let header_end = scaled.windows(4).position(|w| w == b"data").unwrap() + 8;
        assert_eq!(scaled[..header_end], source[..header_end]);
        assert_eq!(data_samples(&scaled), [500, -1_000, 16_383, -16_384]);
    }

    #[test]
    fn full_volume_is_the_file_itself() {
        let source = wav(&[123, -456], false);
        assert_eq!(scale_pcm16_wav(&source, 100).unwrap(), source);
    }

    #[test]
    fn not_a_wav_plays_nothing() {
        assert!(scale_pcm16_wav(b"nope", 50).is_none());
        assert!(scale_pcm16_wav(&wav(&[1], false)[..20], 50).is_none());
    }

    #[test]
    fn the_shipped_sounds_are_16_bit_wavs() {
        for event in SoundEvent::ALL {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("resources")
                .join(sound_file_name(event));
            let bytes = std::fs::read(&path).unwrap_or_else(|_| panic!("{path:?}"));
            assert!(scale_pcm16_wav(&bytes, 50).is_some(), "{path:?}");
        }
    }

    #[test]
    fn silence_at_zero_volume() {
        let scaled = scale_pcm16_wav(&wav(&[1_000, -1_000], false), 0).unwrap();
        assert_eq!(data_samples(&scaled), [0, 0]);
    }

    #[test]
    fn files_are_named_after_the_event() {
        assert_eq!(sound_file_name(SoundEvent::Done), "sound-done.wav");
        assert_eq!(
            sound_file_name(SoundEvent::MeetingStart),
            "sound-meeting-start.wav"
        );
    }
}
