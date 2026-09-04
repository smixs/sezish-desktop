#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use controller::AppController;
use std::sync::Arc;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tray::{
    TrayUi, MENU_DICTATION, MENU_HISTORY, MENU_MODEL, MENU_QUIT, MENU_RECENT_PREFIX, MENU_SETTINGS,
    MENU_UPDATES,
};

mod controller;
mod dto;
mod error;
mod hotkey;
mod hud;
mod ipc;
mod model_idle;
mod obs;
mod platform;
mod settings;
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
            ipc::set_language,
            ipc::set_play_sounds,
            ipc::set_autostart,
            ipc::recent_dictations,
            ipc::copy_dictation,
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
            app.manage(controller);

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

fn open_settings_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html".into()))
        .title("sezish settings")
        .inner_size(520.0, 440.0)
        .resizable(true)
        .build();
}

#[cfg(test)]
mod tests {
    #[test]
    fn binary_smoke_test() {
        assert_eq!(env!("CARGO_PKG_NAME"), "sezish");
    }
}
