//! Canonical WAV encoding for the whole app: 16 kHz mono PCM16.
//!
//! Both the cloud request body and the on-disk history files use exactly this
//! layout; keeping one encoder prevents the two from drifting apart.

/// Sample rate every WAV in the app is encoded at.
pub const SAMPLE_RATE: u32 = 16_000;

/// Encodes PCM16 mono samples into a complete WAV file image
/// (44-byte canonical header + little-endian data).
pub fn encode_pcm16_mono_16k(samples: &[i16]) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + samples.len() * 2);

    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVE");

    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // PCM fmt chunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // audio format: PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // channels: mono
    out.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    out.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes()); // byte rate
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample

    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::encode_pcm16_mono_16k;

    #[test]
    fn header_is_the_canonical_44_bytes_for_16k_mono_pcm16() {
        let wav = encode_pcm16_mono_16k(&[0, 1, -1]);
        let expected_header: [u8; 44] = [
            b'R', b'I', b'F', b'F', 42, 0, 0, 0, // 36 + 6 data bytes
            b'W', b'A', b'V', b'E', b'f', b'm', b't', b' ', 16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0,
            0, // 16000
            0x00, 0x7D, 0, 0, // 32000
            2, 0, 16, 0, b'd', b'a', b't', b'a', 6, 0, 0, 0,
        ];
        assert_eq!(&wav[..44], &expected_header);
        assert_eq!(&wav[44..], &[0u8, 0, 1, 0, 0xFF, 0xFF]);
    }

    #[test]
    fn empty_input_is_a_valid_zero_data_wav() {
        let wav = encode_pcm16_mono_16k(&[]);
        assert_eq!(wav.len(), 44);
        assert_eq!(&wav[4..8], &36u32.to_le_bytes());
    }
}
