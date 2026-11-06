//! What the user hears and sees when a dictation ends. Constants and mapping
//! come from the macOS reference: `SilenceGate.swift`, `SoundEvent.swift`,
//! `HUDNotice.swift`.

#[cfg(test)]
mod tests {
    use super::{HudNotice, SilenceGate, SoundEvent};
    use crate::Outcome;
    use std::time::Duration;

    fn tone(count: usize, amplitude: f32) -> Vec<i16> {
        (0..count)
            .map(|i| (amplitude * (i as f32 * 220.0 * std::f32::consts::TAU / 16_000.0).sin()) as i16)
            .collect()
    }

    #[test]
    fn gate_constants_match_the_macos_reference() {
        assert_eq!(SilenceGate::THRESHOLD_DBFS, -50.0);
        assert_eq!(SilenceGate::WINDOW_SAMPLES, 480);
    }

    #[test]
    fn no_audio_reads_as_the_floor() {
        assert_eq!(SilenceGate::loudest_window_dbfs(&[]), -120.0);
        assert!(SilenceGate::is_near_silent(&[]));
    }

    /// A constant offset is no sound at all: the RMS is taken around each
    /// window's own mean.
    #[test]
    fn a_dc_offset_alone_is_silent() {
        assert!(SilenceGate::is_near_silent(&vec![2_000; 16_000]));
    }

    #[test]
    fn a_whisper_passes_and_room_noise_does_not() {
        // -43 dBFS peak-ish whisper vs. -60 dBFS hiss.
        assert!(!SilenceGate::is_near_silent(&tone(16_000, 300.0)));
        assert!(SilenceGate::is_near_silent(&tone(16_000, 30.0)));
    }

    /// One loud 30 ms window is enough: the gate looks for speech anywhere.
    #[test]
    fn the_loudest_window_decides() {
        let mut samples = vec![0i16; 16_000];
        samples[8_000..8_480].copy_from_slice(&tone(480, 8_000.0));
        assert!(!SilenceGate::is_near_silent(&samples));
        let db = SilenceGate::loudest_window_dbfs(&samples);
        assert!((-16.0..-10.0).contains(&db), "{db}");
    }

    #[test]
    fn sounds_are_named_like_the_mac_files() {
        let names: Vec<_> = SoundEvent::ALL.iter().map(|e| e.resource_name()).collect();
        assert_eq!(
            names,
            [
                "sound-start",
                "sound-stop",
                "sound-done",
                "sound-cancel",
                "sound-error",
                "sound-meeting-start",
                "sound-meeting-stop"
            ]
        );
    }

    #[test]
    fn the_closing_sound_follows_the_outcome() {
        assert_eq!(SoundEvent::after(&Outcome::Inserted), Some(SoundEvent::Done));
        assert_eq!(
            SoundEvent::after(&Outcome::InsertFailed("x".into())),
            Some(SoundEvent::Error)
        );
        assert_eq!(SoundEvent::after(&Outcome::NoText), Some(SoundEvent::Error));
        assert_eq!(SoundEvent::after(&Outcome::Failed), Some(SoundEvent::Error));
        assert_eq!(SoundEvent::after(&Outcome::Ignored), None);
    }

    #[test]
    fn the_hud_notice_follows_the_outcome() {
        assert_eq!(HudNotice::after(&Outcome::Inserted), None);
        assert_eq!(HudNotice::after(&Outcome::Ignored), None);
        assert_eq!(
            HudNotice::after(&Outcome::InsertFailed("x".into())),
            Some(HudNotice::PasteManually)
        );
        assert_eq!(HudNotice::after(&Outcome::NoText), Some(HudNotice::NoText));
        assert_eq!(HudNotice::after(&Outcome::Failed), Some(HudNotice::MicFailed));
    }

    #[test]
    fn notices_that_need_settings_stay_long_enough_to_click() {
        for notice in [HudNotice::MicFailed, HudNotice::ModelMissing] {
            assert!(notice.opens_settings());
            assert_eq!(notice.duration(), Duration::from_secs(4));
        }
        for notice in [HudNotice::PasteManually, HudNotice::NoText] {
            assert!(!notice.opens_settings());
            assert_eq!(notice.duration(), Duration::from_secs(2));
        }
    }
}
