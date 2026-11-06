//! The brand sounds (macOS `SoundPlayer.swift`): one WAV per event, played at
//! the volume from settings (percent, 0–100). `PlaySoundW` has no volume of its own, so the
//! samples are scaled in memory and played from there.

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
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]))
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
