use crate::controller::AppController;
use crate::dto::{
    DictationEntryDto, DictationOutcomeDto, ModelStatusDto, SettingsDto, UpdateCheckDto,
};
use crate::error::AppError;
use crate::settings::{AppLanguage, HotkeyPreference, TranscriptionPreference};
use sez_asr_local::AsrModel;
use sez_hotkey::{vk, Shortcut};
use std::sync::Arc;
use tauri::State;

/// Frozen IPC contract for issues #16 and #17.
///
/// Command names, argument meanings, DTO shapes, and error tagging are public
/// compatibility surfaces. `set_hotkey_key`, `begin_hotkey_capture` and
/// `end_hotkey_capture` are backward-compatible additions for the configurable
/// dictation hotkey (ADR-0010); they extend, not replace, the frozen surface.
#[tauri::command]
pub async fn get_settings(
    controller: State<'_, Arc<AppController>>,
) -> Result<SettingsDto, AppError> {
    controller.settings().await
}

#[tauri::command]
pub async fn set_hotkey_mode(
    controller: State<'_, Arc<AppController>>,
    mode: String,
) -> Result<SettingsDto, AppError> {
    controller.set_hotkey_mode(parse_hotkey_mode(&mode)?).await
}

#[tauri::command]
pub async fn set_hotkey_key(
    controller: State<'_, Arc<AppController>>,
    shortcut: Shortcut,
) -> Result<SettingsDto, AppError> {
    controller.set_hotkey_key(parse_shortcut(shortcut)?).await
}

#[tauri::command]
pub fn begin_hotkey_capture(controller: State<'_, Arc<AppController>>) -> Result<(), AppError> {
    controller.begin_hotkey_capture()
}

#[tauri::command]
pub fn end_hotkey_capture(controller: State<'_, Arc<AppController>>) -> Result<(), AppError> {
    controller.end_hotkey_capture()
}

#[tauri::command]
pub async fn set_transcription_mode(
    controller: State<'_, Arc<AppController>>,
    mode: String,
) -> Result<SettingsDto, AppError> {
    controller
        .set_transcription_mode(parse_transcription_mode(&mode)?)
        .await
}

#[tauri::command]
pub async fn set_local_model(
    controller: State<'_, Arc<AppController>>,
    model: String,
) -> Result<SettingsDto, AppError> {
    controller.set_local_model(parse_local_model(&model)?).await
}

#[tauri::command]
pub async fn set_language(
    controller: State<'_, Arc<AppController>>,
    language: Option<String>,
) -> Result<SettingsDto, AppError> {
    let language = language.as_deref().map(parse_language).transpose()?;
    controller.set_language(language).await
}

#[tauri::command]
pub async fn set_play_sounds(
    controller: State<'_, Arc<AppController>>,
    enabled: bool,
) -> Result<SettingsDto, AppError> {
    controller.set_play_sounds(enabled).await
}

#[tauri::command]
pub async fn set_autostart(
    controller: State<'_, Arc<AppController>>,
    enabled: bool,
) -> Result<SettingsDto, AppError> {
    controller.set_autostart(enabled).await
}

#[tauri::command]
pub async fn recent_dictations(
    controller: State<'_, Arc<AppController>>,
) -> Result<Vec<DictationEntryDto>, AppError> {
    controller.recent_dictations().await
}

#[tauri::command]
pub async fn copy_dictation(
    controller: State<'_, Arc<AppController>>,
    index: u32,
) -> Result<(), AppError> {
    controller.copy_dictation(index).await
}

#[tauri::command]
pub fn model_download_status(
    controller: State<'_, Arc<AppController>>,
) -> Result<ModelStatusDto, AppError> {
    Ok(controller.model_download_status())
}

#[tauri::command]
pub fn download_model(controller: State<'_, Arc<AppController>>) -> Result<(), AppError> {
    controller.inner().download_model()
}

#[tauri::command]
pub async fn start_dictation(controller: State<'_, Arc<AppController>>) -> Result<(), AppError> {
    controller.begin().await
}

#[tauri::command]
pub async fn stop_dictation(
    controller: State<'_, Arc<AppController>>,
) -> Result<DictationOutcomeDto, AppError> {
    controller.end().await
}

#[tauri::command]
pub fn open_history_folder(controller: State<'_, Arc<AppController>>) -> Result<(), AppError> {
    controller.open_history_folder()
}

/// One line from a webview into the file log. The HUD uses it to report whether
/// the plasma rim runs on WebGL or fell back to the CSS gradient; there is no
/// other way to see that from a field log.
#[tauri::command]
pub fn log_line(message: String) {
    crate::obs::log(&message);
}

#[tauri::command]
pub fn app_version(app: tauri::AppHandle) -> Result<String, AppError> {
    // The product version comes from tauri.conf.json (0.1.1), not the internal crate
    // version, so the UI shows the same number the updater compares against.
    Ok(app.package_info().version.to_string())
}

#[tauri::command]
pub async fn check_for_updates(
    controller: State<'_, Arc<AppController>>,
) -> Result<UpdateCheckDto, AppError> {
    controller.update_check().await
}

fn parse_hotkey_mode(mode: &str) -> Result<HotkeyPreference, AppError> {
    match mode {
        "hold" => Ok(HotkeyPreference::Hold),
        "toggle" => Ok(HotkeyPreference::Toggle),
        _ => Err(AppError::invalid(
            "hotkey mode must be either \"hold\" or \"toggle\"",
        )),
    }
}

/// Side-specific modifier keys allowed as a bare `ModifierOnly` shortcut.
const MODIFIER_ONLY_KEYS: [u16; 8] = [
    vk::LSHIFT,
    vk::RSHIFT,
    vk::LCONTROL,
    vk::RCONTROL,
    vk::LMENU,
    vk::RMENU,
    vk::LWIN,
    vk::RWIN,
];

fn is_modifier_vk(key: u16) -> bool {
    MODIFIER_ONLY_KEYS.contains(&key) || matches!(key, vk::CONTROL | vk::MENU | vk::SHIFT)
}

/// Function keys (F1–F12) are legal as a bare `.key` shortcut, unlike typing keys.
fn is_function_key(key: u16) -> bool {
    (0x70..=0x7B).contains(&key)
}

/// Validate the semantic shape of a recorded shortcut. `Shortcut`'s own
/// deserialisation already rejects unknown kinds and modifier names; this adds the
/// key-class rules: a bare modifier must be a real side-specific modifier, and a
/// combo's main key must be a non-modifier that either carries modifiers or is an
/// F-key.
fn parse_shortcut(shortcut: Shortcut) -> Result<Shortcut, AppError> {
    match &shortcut {
        Shortcut::ModifierOnly { vk } => {
            if !MODIFIER_ONLY_KEYS.contains(vk) {
                return Err(AppError::invalid(
                    "modifier-only shortcut must be a side-specific modifier key",
                ));
            }
        }
        Shortcut::Key { vk, mods } => {
            if is_modifier_vk(*vk) {
                return Err(AppError::invalid(
                    "combo shortcut key must not itself be a modifier",
                ));
            }
            if mods.is_empty() && !is_function_key(*vk) {
                return Err(AppError::invalid(
                    "combo shortcut needs at least one modifier unless it is a function key",
                ));
            }
        }
    }
    Ok(shortcut)
}

fn parse_transcription_mode(mode: &str) -> Result<TranscriptionPreference, AppError> {
    match mode {
        "cloud" => Ok(TranscriptionPreference::Cloud),
        "local" => Ok(TranscriptionPreference::Local),
        _ => Err(AppError::invalid(
            "transcription mode must be either \"cloud\" or \"local\"",
        )),
    }
}

fn parse_local_model(model: &str) -> Result<AsrModel, AppError> {
    match model {
        "multilingual" => Ok(AsrModel::Multilingual),
        "ru-en-punctuated" => Ok(AsrModel::RuEnPunctuated),
        _ => Err(AppError::invalid(
            "local model must be either \"multilingual\" or \"ru-en-punctuated\"",
        )),
    }
}

fn parse_language(language: &str) -> Result<AppLanguage, AppError> {
    match language {
        "uz" => Ok(AppLanguage::Uz),
        "ru" => Ok(AppLanguage::Ru),
        _ => Err(AppError::invalid(
            "language must be \"uz\", \"ru\", or null",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::parse_shortcut;
    use sez_hotkey::{vk, Modifiers, Shortcut};

    #[test]
    fn accepts_bare_modifier_and_valid_combos() {
        assert!(parse_shortcut(Shortcut::ModifierOnly { vk: vk::RCONTROL }).is_ok());
        assert!(parse_shortcut(Shortcut::ModifierOnly { vk: vk::LMENU }).is_ok());
        assert!(parse_shortcut(Shortcut::Key {
            vk: 0x51, // Q
            mods: Modifiers::ALT,
        })
        .is_ok());
        // F9 is legal without a modifier.
        assert!(parse_shortcut(Shortcut::Key {
            vk: 0x78,
            mods: Modifiers::empty(),
        })
        .is_ok());
    }

    #[test]
    fn rejects_letter_as_modifier_only() {
        assert!(parse_shortcut(Shortcut::ModifierOnly { vk: 0x51 }).is_err());
        // Generic (non side-specific) modifier code is not a valid bare shortcut.
        assert!(parse_shortcut(Shortcut::ModifierOnly { vk: vk::CONTROL }).is_err());
    }

    #[test]
    fn rejects_modifier_key_as_combo_main_key() {
        assert!(parse_shortcut(Shortcut::Key {
            vk: vk::RCONTROL,
            mods: Modifiers::ALT,
        })
        .is_err());
    }

    #[test]
    fn rejects_typing_key_without_modifiers() {
        assert!(parse_shortcut(Shortcut::Key {
            vk: 0x51, // Q, no modifiers
            mods: Modifiers::empty(),
        })
        .is_err());
    }
}
