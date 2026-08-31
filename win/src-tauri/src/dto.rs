use crate::settings::{AppLanguage, HotkeyPreference, TranscriptionPreference};
use serde::Serialize;
use sez_hotkey::Shortcut;

#[derive(Clone, Debug, Serialize)]
pub struct SettingsDto {
    pub hotkey_mode: HotkeyPreference,
    pub shortcut: Shortcut,
    pub transcription_mode: TranscriptionPreference,
    pub effective_transcription_mode: TranscriptionPreference,
    pub language: Option<AppLanguage>,
    pub resolved_language: AppLanguage,
    pub play_sounds: bool,
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
