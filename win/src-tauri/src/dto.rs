use crate::settings::{AppLanguage, HotkeyPreference, TranscriptionPreference};
use serde::Serialize;
use sez_asr_local::AsrModel;
use sez_hotkey::Shortcut;

#[derive(Clone, Debug, Serialize)]
pub struct SettingsDto {
    pub hotkey_mode: HotkeyPreference,
    pub shortcut: Shortcut,
    pub transcription_mode: TranscriptionPreference,
    pub effective_transcription_mode: TranscriptionPreference,
    pub local_model: AsrModel,
    pub language: Option<AppLanguage>,
    pub resolved_language: AppLanguage,
    pub play_sounds: bool,
    pub sound_volume: u8,
    /// The key itself stays in the backend; the UI only learns whether one is set.
    pub openai_api_key_set: bool,
    pub openai_model: &'static str,
    pub gemini_api_key_set: bool,
    pub gemini_smart_mode: bool,
    pub hud_placement: &'static str,
    pub wave_intensity: &'static str,
    /// Builds without baked cloud credentials do not offer the cloud at all.
    pub cloud_available: bool,
    pub autostart_enabled: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct DictationEntryDto {
    pub text: String,
    pub recorded_at: i64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ModelStatusDto {
    Missing,
    Downloading { fraction: f64 },
    Ready,
    Failed { message: String },
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DictationOutcomeDto {
    Ignored,
    Inserted,
    InsertFailed { message: String },
    NoText,
    Failed,
}

impl From<sez_core::Outcome> for DictationOutcomeDto {
    fn from(outcome: sez_core::Outcome) -> Self {
        match outcome {
            sez_core::Outcome::Ignored => Self::Ignored,
            sez_core::Outcome::Inserted => Self::Inserted,
            sez_core::Outcome::InsertFailed(message) => Self::InsertFailed { message },
            sez_core::Outcome::NoText => Self::NoText,
            sez_core::Outcome::Failed => Self::Failed,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct UpdateCheckDto {
    pub available: bool,
    pub message: String,
}
