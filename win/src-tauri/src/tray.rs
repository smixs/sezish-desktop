use crate::dto::{DictationEntryDto, ModelStatusDto};
use crate::hud::Hud;
use crate::settings::TranscriptionPreference;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::{include_image, App};

pub const MENU_DICTATION: &str = "dictation";
pub const MENU_MODEL: &str = "model";
pub const MENU_SETTINGS: &str = "settings";
pub const MENU_HISTORY: &str = "history";
pub const MENU_UPDATES: &str = "updates";
pub const MENU_QUIT: &str = "quit";
pub const MENU_RECENT_PREFIX: &str = "recent-";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayPhase {
    Idle,
    Recording,
    Transcribing,
}

/// Everything that tells the user what sezish is doing: tray icon + menu state,
/// and the on-screen HUD when it could be created.
pub struct TrayUi {
    state: MenuItem<tauri::Wry>,
    dictation: MenuItem<tauri::Wry>,
    model: MenuItem<tauri::Wry>,
    recent: [MenuItem<tauri::Wry>; 3],
    hud: Option<Hud>,
}

/// Tray glyph per phase: plain, red dot while recording, amber dot while transcribing.
fn phase_icon(phase: TrayPhase) -> Image<'static> {
    match phase {
        TrayPhase::Idle => include_image!("icons/tray-icon.png"),
        TrayPhase::Recording => include_image!("icons/tray-recording.png"),
        TrayPhase::Transcribing => include_image!("icons/tray-transcribing.png"),
    }
}

impl TrayUi {
    pub fn install(app: &App) -> tauri::Result<Self> {
        let state = MenuItem::with_id(app, "state", "Idle", false, None::<&str>)?;
        let dictation =
            MenuItem::with_id(app, MENU_DICTATION, "Start dictation", true, None::<&str>)?;
        let model = MenuItem::with_id(app, MENU_MODEL, "Local model", false, None::<&str>)?;
        let recent = [
            MenuItem::with_id(app, "recent-0", "No recent dictations", false, None::<&str>)?,
            MenuItem::with_id(app, "recent-1", "", false, None::<&str>)?,
            MenuItem::with_id(app, "recent-2", "", false, None::<&str>)?,
        ];
        let settings = MenuItem::with_id(app, MENU_SETTINGS, "Settings…", true, None::<&str>)?;
        let history =
            MenuItem::with_id(app, MENU_HISTORY, "Open history folder", true, None::<&str>)?;
        let updates =
            MenuItem::with_id(app, MENU_UPDATES, "Check for updates", true, None::<&str>)?;
        let quit = MenuItem::with_id(app, MENU_QUIT, "Quit", true, None::<&str>)?;
        let separator_1 = PredefinedMenuItem::separator(app)?;
        let separator_2 = PredefinedMenuItem::separator(app)?;
        let separator_3 = PredefinedMenuItem::separator(app)?;

        let menu = Menu::with_items(
            app,
            &[
                &state,
                &dictation,
                &model,
                &separator_1,
                &recent[0],
                &recent[1],
                &recent[2],
                &history,
                &separator_2,
                &settings,
                &updates,
                &separator_3,
                &quit,
            ],
        )?;
        let tray = app.tray_by_id("main").ok_or_else(|| {
            tauri::Error::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "configured tray icon missing",
            ))
        })?;
        tray.set_menu(Some(menu))?;

        // The HUD is optional: without it the tray icon alone shows the phase.
        let hud = match Hud::create(app.handle()) {
            Ok(hud) => Some(hud),
            Err(error) => {
                crate::obs::log(&format!("hud create failed: {error}"));
                None
            }
        };

        let ui = Self {
            state,
            dictation,
            model,
            recent,
            hud,
        };
        ui.set_phase(app.handle(), TrayPhase::Idle);
        Ok(ui)
    }

    pub fn set_phase(&self, app: &tauri::AppHandle, phase: TrayPhase) {
        let (state, action, enabled, tooltip) = match phase {
            TrayPhase::Idle => ("State: Idle", "Start dictation", true, "sezish — Idle"),
            TrayPhase::Recording => (
                "State: Recording",
                "Stop dictation",
                true,
                "sezish — Recording",
            ),
            TrayPhase::Transcribing => (
                "State: Transcribing",
                "Transcribing…",
                false,
                "sezish — Transcribing",
            ),
        };
        let _ = self.state.set_text(state);
        let _ = self.dictation.set_text(action);
        let _ = self.dictation.set_enabled(enabled);
        if let Some(tray) = app.tray_by_id("main") {
            let _ = tray.set_tooltip(Some(tooltip));
            let _ = tray.set_icon(Some(phase_icon(phase)));
        }
        if let Some(hud) = &self.hud {
            hud.set_phase(phase);
        }
    }

    pub fn set_model(&self, status: &ModelStatusDto, effective_mode: TranscriptionPreference) {
        if effective_mode == TranscriptionPreference::Cloud {
            let _ = self.model.set_text("Transcription: Cloud");
            let _ = self.model.set_enabled(false);
            return;
        }
        let (text, enabled) = match status {
            ModelStatusDto::Missing => ("Download local model", true),
            ModelStatusDto::Downloading { fraction } => {
                let text = format!("Downloading local model… {}%", (fraction * 100.0) as u32);
                let _ = self.model.set_text(text);
                let _ = self.model.set_enabled(false);
                return;
            }
            ModelStatusDto::Ready => ("Local model ready", false),
            ModelStatusDto::Failed { .. } => ("Retry local model download", true),
        };
        let _ = self.model.set_text(text);
        let _ = self.model.set_enabled(enabled);
    }

    pub fn set_recent(&self, entries: &[DictationEntryDto]) {
        for (index, item) in self.recent.iter().enumerate() {
            match entries.get(index) {
                Some(entry) => {
                    let text = if entry.text.is_empty() {
                        "Audio saved without text".to_owned()
                    } else {
                        trim_menu_text(&entry.text)
                    };
                    let _ = item.set_text(text);
                    let _ = item.set_enabled(true);
                }
                None if index == 0 => {
                    let _ = item.set_text("No recent dictations");
                    let _ = item.set_enabled(false);
                }
                None => {
                    let _ = item.set_text("");
                    let _ = item.set_enabled(false);
                }
            }
        }
    }
}

fn trim_menu_text(text: &str) -> String {
    let flattened = text.replace(['\r', '\n'], " ");
    if flattened.chars().count() <= 48 {
        flattened
    } else {
        format!("{}…", flattened.chars().take(48).collect::<String>())
    }
}
