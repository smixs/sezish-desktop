#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use controller::AppController;
use std::sync::Arc;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tray::{
    TrayUi, MENU_DICTATION, MENU_HISTORY, MENU_MODEL, MENU_MODEL_MULTILINGUAL,
    MENU_MODEL_RU_EN_PUNCTUATED, MENU_QUIT, MENU_RECENT_PREFIX, MENU_SETTINGS, MENU_UPDATES,
};

mod controller;
mod dto;
mod error;
mod hotkey;
mod hud;
mod ipc;
mod model_idle;
mod obs;
mod onboarding;
mod platform;
mod settings;
mod sounds;
mod tray;

fn main() {
    // No console in release builds: a setup failure must reach the log and the
    // screen, or the app just vanishes and the user reports "nothing works".
    if let Err(error) = run() {
        let message = format!("sezish failed to start: {error}");
        crate::obs::log(&message);
        platform::show_fatal_dialog(&message);
        std::process::exit(1);
    }
}

fn run() -> tauri::Result<()> {
    tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .invoke_handler(tauri::generate_handler![
            ipc::get_settings,
            ipc::set_hotkey_mode,
            ipc::set_hotkey_key,
            ipc::begin_hotkey_capture,
            ipc::end_hotkey_capture,
            ipc::set_transcription_mode,
            ipc::set_local_model,
            ipc::set_language,
            ipc::set_play_sounds,
            ipc::set_sound_volume,
            ipc::set_openai,
            ipc::set_gemini,
            ipc::set_hud_placement,
            ipc::set_wave_intensity,
            ipc::quit_app,
            ipc::open_key_page,
            ipc::onboarding_action,
            ipc::open_onboarding,
            ipc::hud_notice_clicked,
            ipc::set_autostart,
            ipc::recent_dictations,
            ipc::copy_dictation,
            ipc::history_entries,
            ipc::copy_history_entry,
            ipc::model_download_status,
            ipc::download_model,
            ipc::start_dictation,
            ipc::stop_dictation,
            ipc::open_history_folder,
            ipc::log_line,
            ipc::app_version,
            ipc::check_for_updates,
        ])
        .setup(|app| {
            crate::obs::log("app setup start");
            // Point the ort load-dynamic loader at the bundled ONNX Runtime DLL
            // (ADR-0007) before any local transcriber is built, so local mode does
            // not die trying to find onnxruntime.dll on the system path.
            if let Ok(dll) = app
                .path()
                .resolve("onnxruntime.dll", tauri::path::BaseDirectory::Resource)
            {
                crate::obs::log(&format!("ORT_DYLIB_PATH={}", dll.display()));
                std::env::set_var("ORT_DYLIB_PATH", dll);
            }
            let tray = TrayUi::install(app)?;
            let controller =
                tauri::async_runtime::block_on(AppController::new(app.handle().clone(), tray))?;
            let tour = tauri::async_runtime::block_on(controller.onboarding_needed());
            if tour {
                tauri::async_runtime::block_on(controller.start_onboarding());
            }
            app.manage(controller);
            if tour {
                open_onboarding_window(app.handle());
            }

            let configured_tray = app.tray_by_id("main").ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotFound, "configured tray icon missing")
            })?;
            configured_tray.on_menu_event(handle_menu_event);
            Ok(())
        })
        .run(tauri::generate_context!())
}

fn handle_menu_event(app: &tauri::AppHandle, event: tauri::menu::MenuEvent) {
    let id = event.id().as_ref();
    match id {
        MENU_QUIT => app.exit(0),
        MENU_SETTINGS => open_settings_window(app),
        MENU_HISTORY => {
            let controller = app.state::<Arc<AppController>>();
            let _ = controller.open_history_folder();
        }
        MENU_UPDATES => {
            let controller = Arc::clone(app.state::<Arc<AppController>>().inner());
            tauri::async_runtime::spawn(async move {
                let _ = controller.update_check().await;
            });
        }
        MENU_MODEL => {
            let controller = app.state::<Arc<AppController>>();
            let _ = controller.inner().download_model();
        }
        MENU_MODEL_MULTILINGUAL | MENU_MODEL_RU_EN_PUNCTUATED => {
            let model = if id == MENU_MODEL_MULTILINGUAL {
                sez_asr_local::AsrModel::Multilingual
            } else {
                sez_asr_local::AsrModel::RuEnPunctuated
            };
            let controller = Arc::clone(app.state::<Arc<AppController>>().inner());
            tauri::async_runtime::spawn(async move {
                let _ = controller.set_local_model(model).await;
            });
        }
        MENU_DICTATION => {
            let controller = Arc::clone(app.state::<Arc<AppController>>().inner());
            tauri::async_runtime::spawn(async move {
                if controller.is_recording() {
                    let _ = controller.end().await;
                } else {
                    let _ = controller.begin().await;
                }
            });
        }
        _ if id.starts_with(MENU_RECENT_PREFIX) => {
            let Some(index) = id
                .strip_prefix(MENU_RECENT_PREFIX)
                .and_then(|value| value.parse::<usize>().ok())
            else {
                return;
            };
            let controller = Arc::clone(app.state::<Arc<AppController>>().inner());
            tauri::async_runtime::spawn(async move {
                controller.handle_recent_menu(index).await;
            });
        }
        _ => {}
    }
}

pub(crate) fn open_settings_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    // Mac proportions (720–1100 × 500–580); Mica shows through the sidebar, which
    // the page leaves transparent, and follows the system light or dark theme.
    let builder = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html".into()))
        .title("sezish")
        .inner_size(800.0, 580.0)
        .min_inner_size(720.0, 500.0)
        .resizable(true)
        .effects(tauri::utils::config::WindowEffectsConfig {
            effects: vec![tauri::window::Effect::Mica],
            ..Default::default()
        });
    // Gated out of the macOS dev build, as in the HUD.
    #[cfg(not(target_os = "macos"))]
    let builder = builder.transparent(true);
    let _ = builder.build();
}

/// The first-run tour (Mac `OnboardingWindow`: 560 × 480, fixed).
pub(crate) fn open_onboarding_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("onboarding") {
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let builder =
        WebviewWindowBuilder::new(app, "onboarding", WebviewUrl::App("onboarding.html".into()))
            .title("sezish")
            .inner_size(560.0, 500.0)
            .resizable(false)
            .maximizable(false)
            .center()
            .effects(tauri::utils::config::WindowEffectsConfig {
                effects: vec![tauri::window::Effect::Mica],
                ..Default::default()
            });
    #[cfg(not(target_os = "macos"))]
    let builder = builder.transparent(true);
    let _ = builder.build();
}

#[cfg(test)]
mod tests {
    #[test]
    fn binary_smoke_test() {
        assert_eq!(env!("CARGO_PKG_NAME"), "sezish");
    }
}
