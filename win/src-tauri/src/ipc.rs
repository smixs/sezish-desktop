use crate::controller::AppController;
use crate::dto::{
    DictationEntryDto, DictationOutcomeDto, ModelStatusDto, SettingsDto, UpdateCheckDto,
};
use crate::error::AppError;
use crate::hud::HudPlacement;
use crate::settings::{AppLanguage, HotkeyPreference, OpenAiModel, TranscriptionPreference};
use sez_asr_local::AsrModel;
use sez_core::wave::WaveIntensity;
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

/// A clickable HUD pill: something to fix in Settings.
#[tauri::command]
pub fn hud_notice_clicked(app: tauri::AppHandle) {
    crate::open_settings_window(&app);
}

#[tauri::command]
pub async fn set_openai(
    controller: State<'_, Arc<AppController>>,
    key: Option<String>,
    model: Option<String>,
) -> Result<SettingsDto, AppError> {
    let model = model
        .as_deref()
        .map(|name| {
            OpenAiModel::from_name(name)
                .ok_or_else(|| AppError::invalid(format!("unknown OpenAI model {name}")))
        })
        .transpose()?;
    controller.set_openai(key, model).await
}

#[tauri::command]
pub async fn set_gemini(
    controller: State<'_, Arc<AppController>>,
    key: Option<String>,
    smart_mode: Option<bool>,
) -> Result<SettingsDto, AppError> {
    controller.set_gemini(key, smart_mode).await
}

#[tauri::command]
pub async fn set_hud_placement(
    controller: State<'_, Arc<AppController>>,
    placement: String,
) -> Result<SettingsDto, AppError> {
    controller
        .set_hud_placement(parse_hud_placement(&placement)?)
        .await
}

#[tauri::command]
pub async fn set_wave_intensity(
    controller: State<'_, Arc<AppController>>,
    intensity: String,
) -> Result<SettingsDto, AppError> {
    controller
        .set_wave_intensity(parse_wave_intensity(&intensity)?)
        .await
}

#[tauri::command]
pub fn open_key_page(provider: String) -> Result<(), AppError> {
    crate::platform::open_url(key_page(&provider)?)
}

/// `poll`, `grant_microphone`, `choose_local`, `choose_cloud`, `retry`,
/// `continue`, `back`.
fn onboarding_input(action: &str) -> Result<crate::onboarding::Input, AppError> {
    use crate::onboarding::{Engine, Input, Microphone};
    Ok(match action {
        // The microphone value is read fresh by the controller.
        "poll" => Input::Status(Microphone::Undetermined),
        "grant_microphone" => Input::GrantMicrophone,
        "choose_local" => Input::ChooseEngine(Engine::Local),
        "choose_cloud" => Input::ChooseEngine(Engine::Cloud),
        "retry" => Input::RetryDownload,
        "continue" => Input::Continue,
        "back" => Input::Back,
        _ => {
            return Err(AppError::invalid(format!(
                "unknown onboarding action {action}"
            )))
        }
    })
}

#[tauri::command]
pub async fn onboarding_action(
    controller: State<'_, Arc<AppController>>,
    action: String,
) -> Result<crate::dto::OnboardingDto, AppError> {
    controller
        .onboarding_action(onboarding_input(&action)?)
        .await
}

/// «Пройти настройку заново» in the settings window.
#[tauri::command]
pub async fn open_onboarding(
    app: tauri::AppHandle,
    controller: State<'_, Arc<AppController>>,
) -> Result<(), AppError> {
    controller.start_onboarding().await;
    crate::open_onboarding_window(&app);
    Ok(())
}

/// «Выйти из sezish» at the foot of the settings sidebar, as on the Mac.
#[tauri::command]
pub fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

#[tauri::command]
pub async fn set_sound_volume(
    controller: State<'_, Arc<AppController>>,
    percent: u8,
) -> Result<SettingsDto, AppError> {
    controller.set_sound_volume(percent).await
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
pub async fn history_entries(
    controller: State<'_, Arc<AppController>>,
) -> Result<Vec<DictationEntryDto>, AppError> {
    controller.history_entries().await
}

#[tauri::command]
pub async fn copy_history_entry(
    controller: State<'_, Arc<AppController>>,
    index: u32,
) -> Result<(), AppError> {
    controller.copy_history_entry(index).await
}

#[tauri::command]
pub async fn retry_history_entry(
    controller: State<'_, Arc<AppController>>,
    index: u32,
) -> Result<String, AppError> {
    controller.retry_history_entry(index).await
}

#[tauri::command]
pub async fn play_history_entry(
    controller: State<'_, Arc<AppController>>,
    index: u32,
) -> Result<(), AppError> {
    controller.play_history_entry(index).await
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
        "openai" => Ok(TranscriptionPreference::Openai),
        "gemini" => Ok(TranscriptionPreference::Gemini),
        _ => Err(AppError::invalid(
            "transcription mode must be \"cloud\", \"local\", \"openai\" or \"gemini\"",
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

/// Where «Получить ключ» leads (Mac `RecognitionPane`).
fn key_page(provider: &str) -> Result<&'static str, AppError> {
    match provider {
        "gemini" => Ok("https://aistudio.google.com/apikey"),
        "openai" => Ok("https://platform.openai.com/api-keys"),
        _ => Err(AppError::invalid(format!(
            "unknown key provider {provider}"
        ))),
    }
}

fn parse_hud_placement(name: &str) -> Result<HudPlacement, AppError> {
    HudPlacement::from_name(name)
        .ok_or_else(|| AppError::invalid(format!("unknown HUD placement {name}")))
}

fn parse_wave_intensity(name: &str) -> Result<WaveIntensity, AppError> {
    WaveIntensity::from_name(name)
        .ok_or_else(|| AppError::invalid(format!("unknown wave intensity {name}")))
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
    use super::{key_page, parse_hud_placement, parse_wave_intensity};

    /// «Получить ключ» opens one of two fixed pages, never a URL from the window.
    #[test]
    fn key_pages_are_fixed_per_provider() {
        assert_eq!(
            key_page("gemini").unwrap(),
            "https://aistudio.google.com/apikey"
        );
        assert_eq!(
            key_page("openai").unwrap(),
            "https://platform.openai.com/api-keys"
        );
        assert!(key_page("https://example.com").is_err());
    }
    use crate::hud::HudPlacement;
    use sez_core::wave::WaveIntensity;

    /// The settings window sends the stored names; the Mac's menu-bar and notch
    /// places do not exist here.
    #[test]
    fn hud_placement_and_wave_intensity_parse_by_stored_name() {
        assert_eq!(parse_hud_placement("top").unwrap(), HudPlacement::Top);
        assert_eq!(parse_hud_placement("bottom").unwrap(), HudPlacement::Bottom);
        assert!(parse_hud_placement("notch").is_err());
        assert_eq!(parse_wave_intensity("bold").unwrap(), WaveIntensity::Bold);
        assert!(parse_wave_intensity("loud").is_err());
    }
}

#[cfg(test)]
mod shortcut_tests {
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
