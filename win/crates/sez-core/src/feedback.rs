//! What the user hears and sees when a dictation ends. Constants and mapping
//! come from the macOS reference: `SilenceGate.swift`, `SoundEvent.swift`,
//! `HUDNotice.swift`.

use crate::Outcome;
use std::time::Duration;

/// hex's `dictate.silence-gate`: a take whose loudest 30 ms window, offset
/// removed, stays under -50 dBFS holds no speech. Engines invent closing
/// phrases ("Спасибо.") on such audio, so it is dropped before transcription.
/// The threshold is conservative: a whisper sits near -43 dBFS.
pub struct SilenceGate;

impl SilenceGate {
    pub const THRESHOLD_DBFS: f32 = -50.0;
    /// 30 ms at 16 kHz.
    pub const WINDOW_SAMPLES: usize = 480;

    pub fn is_near_silent(samples: &[i16]) -> bool {
        Self::loudest_window_dbfs(samples) < Self::THRESHOLD_DBFS
    }

    /// The loudest window's RMS around its own mean, in dBFS; -120 for no audio.
    pub fn loudest_window_dbfs(samples: &[i16]) -> f32 {
        let loudest = samples
            .chunks(Self::WINDOW_SAMPLES)
            .map(|window| {
                let count = window.len() as f64;
                let values = window.iter().map(|&s| f64::from(s) / 32_768.0);
                let mean = values.clone().sum::<f64>() / count;
                let variance = values.map(|v| (v - mean) * (v - mean)).sum::<f64>() / count;
                variance.sqrt()
            })
            .fold(0.0_f64, f64::max);
        (20.0 * loudest.max(1e-6).log10()) as f32
    }
}

/// The app's brand sounds, one per event; the files ship as `<resource_name>.wav`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SoundEvent {
    Start,
    Stop,
    Done,
    Cancel,
    Error,
    MeetingStart,
    MeetingStop,
}

impl SoundEvent {
    pub const ALL: [SoundEvent; 7] = [
        Self::Start,
        Self::Stop,
        Self::Done,
        Self::Cancel,
        Self::Error,
        Self::MeetingStart,
        Self::MeetingStop,
    ];

    pub fn resource_name(self) -> &'static str {
        match self {
            Self::Start => "sound-start",
            Self::Stop => "sound-stop",
            Self::Done => "sound-done",
            Self::Cancel => "sound-cancel",
            Self::Error => "sound-error",
            Self::MeetingStart => "sound-meeting-start",
            Self::MeetingStop => "sound-meeting-stop",
        }
    }

    /// The sound that closes a dictation: done when the text landed, error when
    /// the user has something to do about it, silence for a take that never counted.
    pub fn after(outcome: &Outcome) -> Option<Self> {
        match outcome {
            Outcome::Inserted => Some(Self::Done),
            Outcome::InsertFailed(_) | Outcome::NoText | Outcome::Failed => Some(Self::Error),
            Outcome::Ignored => None,
        }
    }
}

/// A short message the dictation HUD shows in place of a notification: the
/// circle widens into a pill with the text and the error sound plays.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HudNotice {
    /// The paste did not go through; the text is on the clipboard.
    PasteManually,
    /// The engine heard nothing; the audio is kept in history.
    NoText,
    /// The microphone did not record.
    MicFailed,
    /// Local recognition has no downloaded model yet.
    ModelMissing,
}

impl HudNotice {
    /// The ones the user fixes in Settings: a click on the pill opens them.
    pub fn opens_settings(self) -> bool {
        matches!(self, Self::MicFailed | Self::ModelMissing)
    }

    /// Time on screen; a clickable pill waits long enough to be clicked.
    pub fn duration(self) -> Duration {
        Duration::from_secs(if self.opens_settings() { 4 } else { 2 })
    }

    pub fn after(outcome: &Outcome) -> Option<Self> {
        match outcome {
            Outcome::Inserted | Outcome::Ignored => None,
            Outcome::InsertFailed(_) => Some(Self::PasteManually),
            Outcome::NoText => Some(Self::NoText),
            Outcome::Failed => Some(Self::MicFailed),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{HudNotice, SilenceGate, SoundEvent};
    use crate::Outcome;
    use std::time::Duration;

    fn tone(count: usize, amplitude: f32) -> Vec<i16> {
        (0..count)
            .map(|i| {
                (amplitude * (i as f32 * 220.0 * std::f32::consts::TAU / 16_000.0).sin()) as i16
            })
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
        samples[7_680..8_160].copy_from_slice(&tone(480, 8_000.0));
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
        assert_eq!(
            SoundEvent::after(&Outcome::Inserted),
            Some(SoundEvent::Done)
        );
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
        assert_eq!(
            HudNotice::after(&Outcome::Failed),
            Some(HudNotice::MicFailed)
        );
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
