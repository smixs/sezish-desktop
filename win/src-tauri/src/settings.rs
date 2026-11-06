use serde::{Deserialize, Serialize};
use serde_json::Value;
use sez_asr_local::AsrModel;
use sez_hotkey::Shortcut;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HotkeyPreference {
    Hold,
    Toggle,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TranscriptionPreference {
    Cloud,
    Local,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AppLanguage {
    Uz,
    Ru,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct Settings {
    pub hotkey_mode: HotkeyPreference,
    pub shortcut: Shortcut,
    pub transcription_mode: TranscriptionPreference,
    /// Which downloaded bundle local transcription runs. Old settings files have no
    /// such key and keep the multilingual model they already have on disk.
    #[serde(default)]
    pub local_model: AsrModel,
    pub language: Option<AppLanguage>,
    pub play_sounds: bool,
    /// Percent, 0–100 (Mac `soundVolume` 0…1, default 0.5).
    #[serde(default = "default_sound_volume")]
    pub sound_volume: u8,
}

fn default_sound_volume() -> u8 {
    50
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            hotkey_mode: HotkeyPreference::Hold,
            shortcut: Shortcut::default(),
            transcription_mode: TranscriptionPreference::Cloud,
            local_model: AsrModel::default(),
            language: None,
            play_sounds: true,
            sound_volume: default_sound_volume(),
        }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Self {
        let Ok(bytes) = fs::read(path) else {
            return Self::default();
        };
        let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
            return Self::default();
        };

        let mut settings = Self::default();
        if let Some(mode) = value
            .get("hotkey_mode")
            .and_then(|value| serde_json::from_value(value.clone()).ok())
        {
            settings.hotkey_mode = mode;
        }
        if let Some(stored) = value.get("shortcut") {
            match serde_json::from_value(stored.clone()) {
                Ok(shortcut) => settings.shortcut = shortcut,
                // Silently falling back to the default is what made the startup log
                // disagree with settings.json and with the hotkey that actually fired.
                Err(error) => crate::obs::log(&format!(
                    "settings: shortcut {stored} ignored, keeping default: {error}"
                )),
            }
        }
        if let Some(mode) = value
            .get("transcription_mode")
            .and_then(|value| serde_json::from_value(value.clone()).ok())
        {
            settings.transcription_mode = mode;
        }
        if let Some(model) = value
            .get("local_model")
            .and_then(|value| serde_json::from_value(value.clone()).ok())
        {
            settings.local_model = model;
        }
        if let Some(language) = value.get("language") {
            settings.language = serde_json::from_value(language.clone()).unwrap_or(None);
        }
        if let Some(play_sounds) = value.get("play_sounds").and_then(Value::as_bool) {
            settings.play_sounds = play_sounds;
        }
        if let Some(volume) = value.get("sound_volume").and_then(Value::as_u64) {
            settings.sound_volume = volume.min(100) as u8;
        }
        settings
    }

    pub fn save(&self, path: &Path) -> Result<(), std::io::Error> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        fs::write(path, data)
    }
}

pub fn settings_path() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_default()
        .join("sezish")
        .join("settings.json")
}

pub fn effective_transcription_mode(
    preference: TranscriptionPreference,
    has_cloud_credentials: bool,
) -> TranscriptionPreference {
    match (preference, has_cloud_credentials) {
        (TranscriptionPreference::Cloud, true) => TranscriptionPreference::Cloud,
        (TranscriptionPreference::Cloud, false) | (TranscriptionPreference::Local, _) => {
            TranscriptionPreference::Local
        }
    }
}

pub fn resolve_system_language(locale: &str) -> AppLanguage {
    if locale.starts_with("uz") {
        AppLanguage::Uz
    } else {
        AppLanguage::Ru
    }
}

#[cfg(test)]
mod tests {
    use super::{
        effective_transcription_mode, resolve_system_language, AppLanguage, AsrModel,
        HotkeyPreference, Settings, TranscriptionPreference,
    };
    use crate::hud::HudPlacement;
    use sez_core::wave::WaveIntensity;
    use sez_hotkey::{Modifiers, Shortcut};
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn settings_load_merges_known_values_and_defaults_missing_or_stale_values() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let path = directory.path().join("settings.json");
        fs::write(
            &path,
            r#"{
                "hotkey_mode": "stale",
                "transcription_mode": "local",
                "local_model": "ru-en-punctuated",
                "language": "uz",
                "play_sounds": false
            }"#,
        )
        .expect("settings fixture should be written");

        let loaded = Settings::load(&path);

        assert_eq!(
            loaded,
            Settings {
                hotkey_mode: HotkeyPreference::Hold,
                shortcut: Shortcut::default(),
                transcription_mode: TranscriptionPreference::Local,
                local_model: AsrModel::RuEnPunctuated,
                language: Some(AppLanguage::Uz),
                play_sounds: false,
                sound_volume: 50,
                hud_placement: HudPlacement::Bottom,
                wave_intensity: WaveIntensity::Lively,
            }
        );
    }

    /// Mac: HUD placement and wave intensity, stored by name; unknown names
    /// (the Mac's notch, a typo) fall back to the defaults.
    #[test]
    fn hud_placement_and_wave_intensity_load_by_name() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let path = directory.path().join("settings.json");
        let defaults = Settings::default();
        assert_eq!(defaults.hud_placement, HudPlacement::Bottom);
        assert_eq!(defaults.wave_intensity, WaveIntensity::Lively);

        fs::write(&path, r#"{ "hud_placement": "top", "wave_intensity": "bold" }"#)
            .expect("fixture should be written");
        let loaded = Settings::load(&path);
        assert_eq!(loaded.hud_placement, HudPlacement::Top);
        assert_eq!(loaded.wave_intensity, WaveIntensity::Bold);

        fs::write(&path, r#"{ "hud_placement": "notch", "wave_intensity": 3 }"#)
            .expect("fixture should be written");
        let loaded = Settings::load(&path);
        assert_eq!(loaded.hud_placement, HudPlacement::Bottom);
        assert_eq!(loaded.wave_intensity, WaveIntensity::Lively);

        let saved = Settings {
            hud_placement: HudPlacement::Top,
            wave_intensity: WaveIntensity::Calm,
            ..Default::default()
        };
        saved.save(&path).expect("settings should save");
        assert_eq!(Settings::load(&path), saved);
    }

    /// Mac: `soundVolume` 0…1, default 0.5. Stored here as a percent so the
    /// settings stay comparable; anything out of range is pulled back in.
    #[test]
    fn sound_volume_defaults_to_half_and_is_clamped() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let path = directory.path().join("settings.json");
        assert_eq!(Settings::default().sound_volume, 50);

        fs::write(&path, r#"{ "sound_volume": 30 }"#).expect("fixture should be written");
        assert_eq!(Settings::load(&path).sound_volume, 30);

        fs::write(&path, r#"{ "sound_volume": 300 }"#).expect("fixture should be written");
        assert_eq!(Settings::load(&path).sound_volume, 100);

        fs::write(&path, r#"{ "sound_volume": -5 }"#).expect("fixture should be written");
        assert_eq!(Settings::load(&path).sound_volume, 50);
    }

    #[test]
    fn settings_without_shortcut_field_migrate_to_default_right_ctrl() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let path = directory.path().join("legacy.json");
        // A pre-0.1.1 settings file has no "shortcut" key at all.
        fs::write(
            &path,
            r#"{ "hotkey_mode": "toggle", "transcription_mode": "cloud", "language": null, "play_sounds": true }"#,
        )
        .expect("legacy fixture should be written");

        let loaded = Settings::load(&path);
        assert_eq!(loaded.shortcut, Shortcut::default());
        // Pre-0.1.10 files have no "local_model" either: they keep the model on disk.
        assert_eq!(loaded.local_model, AsrModel::Multilingual);
    }

    #[test]
    fn settings_roundtrip_a_custom_key_combo_shortcut() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let path = directory.path().join("settings.json");
        let settings = Settings {
            shortcut: Shortcut::Key {
                vk: 0x51,
                mods: Modifiers::ALT,
            },
            ..Default::default()
        };
        settings.save(&path).expect("settings should save");

        assert_eq!(Settings::load(&path), settings);
    }

    #[test]
    fn corrupt_shortcut_falls_back_to_default() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let path = directory.path().join("bad-shortcut.json");
        fs::write(
            &path,
            r#"{ "shortcut": { "kind": "nonsense" }, "play_sounds": false }"#,
        )
        .expect("fixture should be written");

        let loaded = Settings::load(&path);
        assert_eq!(loaded.shortcut, Shortcut::default());
        assert!(!loaded.play_sounds);
    }

    #[test]
    fn missing_or_corrupt_settings_load_exact_defaults_without_crashing() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let missing = directory.path().join("missing.json");
        assert_eq!(Settings::load(&missing), Settings::default());

        let corrupt = directory.path().join("corrupt.json");
        fs::write(&corrupt, b"{truncated").expect("corrupt fixture should be written");
        assert_eq!(Settings::load(&corrupt), Settings::default());
        assert_eq!(
            Settings::default(),
            Settings {
                hotkey_mode: HotkeyPreference::Hold,
                shortcut: Shortcut::default(),
                transcription_mode: TranscriptionPreference::Cloud,
                local_model: AsrModel::Multilingual,
                language: None,
                play_sounds: true,
                sound_volume: 50,
                hud_placement: HudPlacement::Bottom,
                wave_intensity: WaveIntensity::Lively,
            }
        );
    }

    #[test]
    fn cloud_preference_degrades_to_local_without_baked_credentials() {
        assert_eq!(
            effective_transcription_mode(TranscriptionPreference::Cloud, true),
            TranscriptionPreference::Cloud
        );
        assert_eq!(
            effective_transcription_mode(TranscriptionPreference::Cloud, false),
            TranscriptionPreference::Local
        );
        assert_eq!(
            effective_transcription_mode(TranscriptionPreference::Local, true),
            TranscriptionPreference::Local
        );
        assert_eq!(
            effective_transcription_mode(TranscriptionPreference::Local, false),
            TranscriptionPreference::Local
        );
    }

    #[test]
    fn system_language_is_uz_only_when_the_locale_starts_with_uz() {
        assert_eq!(resolve_system_language("uz-Latn-UZ"), AppLanguage::Uz);
        assert_eq!(resolve_system_language("uz_UZ"), AppLanguage::Uz);
        assert_eq!(resolve_system_language("ru-RU"), AppLanguage::Ru);
        assert_eq!(resolve_system_language("en-US"), AppLanguage::Ru);
        assert_eq!(resolve_system_language(""), AppLanguage::Ru);
    }
}
