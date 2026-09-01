use crate::dto::{
    DictationEntryDto, DictationOutcomeDto, ModelStatusDto, SettingsDto, UpdateCheckDto,
};
use crate::error::AppError;
use crate::hotkey::HotkeyAdapter;
use crate::model_idle::ModelIdlePolicy;
use crate::platform::{
    autostart_enabled, copy_text, open_history_folder, play_start_sound_if_available,
    set_autostart, system_locale, PlatformInserter, SystemClock,
};
use crate::settings::{
    effective_transcription_mode, resolve_system_language, settings_path, AppLanguage,
    HotkeyPreference, Settings, TranscriptionPreference,
};
use crate::tray::{TrayPhase, TrayUi};
use async_trait::async_trait;
use sez_asr_cloud::CloudTranscriber;
use sez_asr_local::{LocalTranscriber, ModelDownloader, ModelStore};
use sez_audio::CpalMic;
use sez_core::{Clock, Coordinator, History, HistoryEntry, SezError, State, Transcriber};
use sez_history::FileHistory;
use sez_hotkey::{Command, HotkeyMode, Shortcut};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as SyncMutex, MutexGuard};
use std::time::{Duration, UNIX_EPOCH};
use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;
use tokio::sync::Mutex;

const MODEL_IDLE_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MODEL_IDLE_POLL: Duration = Duration::from_secs(30);

type AppCoordinator = Coordinator<CpalMic, ActiveTranscriber, PlatformInserter, SharedHistory>;

enum ActiveTranscriber {
    Cloud(CloudTranscriber),
    Local(LocalTranscriber),
}

#[async_trait]
impl Transcriber for ActiveTranscriber {
    fn warmup(&self) {
        match self {
            Self::Cloud(transcriber) => transcriber.warmup(),
            Self::Local(transcriber) => transcriber.warmup(),
        }
    }

    async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError> {
        match self {
            Self::Cloud(transcriber) => Transcriber::transcribe(transcriber, samples).await,
            Self::Local(transcriber) => Transcriber::transcribe(transcriber, samples).await,
        }
    }
}

#[derive(Clone)]
struct SharedHistory {
    inner: Arc<Mutex<FileHistory>>,
}

impl SharedHistory {
    fn new(history: FileHistory) -> Self {
        Self {
            inner: Arc::new(Mutex::new(history)),
        }
    }

    async fn recent_three(&self) -> Result<Vec<DictationEntryDto>, AppError> {
        let history = self.inner.lock().await;
        history
            .recent()
            .await?
            .into_iter()
            .take(3)
            .map(history_dto)
            .collect()
    }
}

#[async_trait]
impl History for SharedHistory {
    async fn record(&mut self, text: &str, audio: &[i16]) -> Result<(), SezError> {
        self.inner.lock().await.record(text, audio).await
    }

    async fn recent(&self) -> Result<Vec<HistoryEntry>, SezError> {
        self.inner.lock().await.recent().await
    }
}

struct RuntimeState {
    settings: Settings,
    coordinator: Option<AppCoordinator>,
    coordinator_mode: Option<TranscriptionPreference>,
}

struct CloudCredentials {
    endpoint: String,
    key: String,
}

enum HotkeyEvent {
    Command(Command),
    Cancel,
}

pub struct AppController {
    app: AppHandle,
    tray: TrayUi,
    runtime: Mutex<RuntimeState>,
    settings_path: PathBuf,
    history_path: PathBuf,
    history: SharedHistory,
    model_store: ModelStore,
    model_status: SyncMutex<ModelStatusDto>,
    model_idle: SyncMutex<ModelIdlePolicy>,
    clock: Arc<SystemClock>,
    recording: Arc<AtomicBool>,
    hotkey: SyncMutex<Option<HotkeyAdapter>>,
    cloud_credentials: Option<CloudCredentials>,
}

impl AppController {
    pub async fn new(app: AppHandle, tray: TrayUi) -> Result<Arc<Self>, AppError> {
        let settings_path = settings_path();
        let history_path = data_root().join("DictationHistory");
        let settings = Settings::load(&settings_path);
        let history = SharedHistory::new(FileHistory::new(&history_path)?);
        let model_store = ModelStore::new(None, None);
        let model_status = if model_store.is_ready() {
            ModelStatusDto::Ready
        } else {
            ModelStatusDto::Missing
        };
        let controller = Arc::new(Self {
            app,
            tray,
            runtime: Mutex::new(RuntimeState {
                settings,
                coordinator: None,
                coordinator_mode: None,
            }),
            settings_path,
            history_path,
            history,
            model_store,
            model_status: SyncMutex::new(model_status),
            model_idle: SyncMutex::new(ModelIdlePolicy::new(MODEL_IDLE_TIMEOUT)),
            clock: Arc::new(SystemClock::new()),
            recording: Arc::new(AtomicBool::new(false)),
            hotkey: SyncMutex::new(None),
            cloud_credentials: baked_cloud_credentials(),
        });

        {
            let mut runtime = controller.runtime.lock().await;
            controller.rebuild_locked(&mut runtime, false)?;
        }
        controller.install_hotkey().await?;
        controller.refresh_tray().await;
        controller.start_model_idle_monitor();
        Ok(controller)
    }

    pub fn is_recording(&self) -> bool {
        self.recording.load(Ordering::Acquire)
    }

    pub async fn begin(&self) -> Result<(), AppError> {
        let mut runtime = self.runtime.lock().await;
        if runtime
            .coordinator
            .as_ref()
            .is_some_and(|coordinator| coordinator.state() != State::Idle)
        {
            return Err(AppError::busy("dictation is already active"));
        }
        if runtime.coordinator.is_none() {
            self.rebuild_locked(&mut runtime, true)?;
        }
        let coordinator = runtime.coordinator.as_mut().ok_or_else(|| {
            AppError::not_ready("Local model is required. Download it from the sezish tray menu.")
        })?;

        coordinator.begin().await;
        if coordinator.state() != State::Recording {
            self.recording.store(false, Ordering::Release);
            self.tray.set_phase(&self.app, TrayPhase::Idle);
            return Err(AppError::not_ready(
                "Could not start microphone capture. Check Windows microphone permission.",
            ));
        }

        self.recording.store(true, Ordering::Release);
        if runtime.coordinator_mode == Some(TranscriptionPreference::Local) {
            lock_recover(&self.model_idle).on_active();
        }
        let play_sounds = runtime.settings.play_sounds;
        drop(runtime);
        self.tray.set_phase(&self.app, TrayPhase::Recording);
        play_start_sound_if_available(play_sounds);
        Ok(())
    }

    pub async fn end(&self) -> Result<DictationOutcomeDto, AppError> {
        self.recording.store(false, Ordering::Release);
        let mut runtime = self.runtime.lock().await;
        let Some(coordinator) = runtime.coordinator.as_mut() else {
            self.tray.set_phase(&self.app, TrayPhase::Idle);
            return Ok(DictationOutcomeDto::Ignored);
        };
        if coordinator.state() != State::Recording {
            self.tray.set_phase(&self.app, TrayPhase::Idle);
            return Ok(DictationOutcomeDto::Ignored);
        }

        self.tray.set_phase(&self.app, TrayPhase::Transcribing);
        let outcome = coordinator.end().await;
        let used_mode = runtime.coordinator_mode;
        if used_mode == Some(TranscriptionPreference::Local) {
            lock_recover(&self.model_idle).on_idle(self.clock.as_ref());
        }
        self.apply_pending_mode_locked(&mut runtime)?;
        drop(runtime);
        self.tray.set_phase(&self.app, TrayPhase::Idle);
        self.refresh_recent().await;
        self.refresh_model_menu().await;
        Ok(outcome.into())
    }

    pub async fn cancel(&self) -> Result<(), AppError> {
        self.recording.store(false, Ordering::Release);
        let mut runtime = self.runtime.lock().await;
        if let Some(coordinator) = runtime.coordinator.as_mut() {
            if coordinator.state() == State::Recording {
                self.tray.set_phase(&self.app, TrayPhase::Transcribing);
                coordinator.cancel().await;
                if runtime.coordinator_mode == Some(TranscriptionPreference::Local) {
                    lock_recover(&self.model_idle).on_idle(self.clock.as_ref());
                }
                self.apply_pending_mode_locked(&mut runtime)?;
            }
        }
        drop(runtime);
        self.tray.set_phase(&self.app, TrayPhase::Idle);
        self.refresh_model_menu().await;
        Ok(())
    }

    pub async fn settings(&self) -> Result<SettingsDto, AppError> {
        let runtime = self.runtime.lock().await;
        self.settings_dto(&runtime.settings)
    }

    pub async fn set_hotkey_mode(&self, mode: HotkeyPreference) -> Result<SettingsDto, AppError> {
        if self.is_recording() {
            let _ = self.end().await?;
        }
        {
            let mut runtime = self.runtime.lock().await;
            runtime.settings.hotkey_mode = mode;
            runtime.settings.save(&self.settings_path)?;
        }
        if let Some(hotkey) = lock_recover(&self.hotkey).as_ref() {
            hotkey
                .set_mode(hotkey_mode(mode))
                .map_err(|error| AppError::platform(error.to_string()))?;
        }
        self.settings().await
    }

    pub async fn set_hotkey_key(&self, shortcut: Shortcut) -> Result<SettingsDto, AppError> {
        if self.is_recording() {
            let _ = self.end().await?;
        }
        {
            let mut runtime = self.runtime.lock().await;
            runtime.settings.shortcut = shortcut.clone();
            runtime.settings.save(&self.settings_path)?;
        }
        if let Some(hotkey) = lock_recover(&self.hotkey).as_ref() {
            hotkey
                .set_shortcut(shortcut)
                .map_err(|error| AppError::platform(error.to_string()))?;
        }
        self.settings().await
    }

    /// Silence the global hook while the settings UI records a new shortcut, so the
    /// keys being pressed to record don't also trigger dictation.
    pub fn begin_hotkey_capture(&self) -> Result<(), AppError> {
        if let Some(hotkey) = lock_recover(&self.hotkey).as_ref() {
            hotkey
                .suspend()
                .map_err(|error| AppError::platform(error.to_string()))?;
        }
        Ok(())
    }

    pub fn end_hotkey_capture(&self) -> Result<(), AppError> {
        if let Some(hotkey) = lock_recover(&self.hotkey).as_ref() {
            hotkey
                .resume()
                .map_err(|error| AppError::platform(error.to_string()))?;
        }
        Ok(())
    }

    pub async fn set_transcription_mode(
        &self,
        mode: TranscriptionPreference,
    ) -> Result<SettingsDto, AppError> {
        {
            let mut runtime = self.runtime.lock().await;
            runtime.settings.transcription_mode = mode;
            runtime.settings.save(&self.settings_path)?;
            self.apply_pending_mode_locked(&mut runtime)?;
        }
        self.refresh_model_menu().await;
        self.settings().await
    }

    pub async fn set_language(
        &self,
        language: Option<AppLanguage>,
    ) -> Result<SettingsDto, AppError> {
        {
            let mut runtime = self.runtime.lock().await;
            runtime.settings.language = language;
            runtime.settings.save(&self.settings_path)?;
        }
        self.settings().await
    }

    pub async fn set_play_sounds(&self, enabled: bool) -> Result<SettingsDto, AppError> {
        {
            let mut runtime = self.runtime.lock().await;
            runtime.settings.play_sounds = enabled;
            runtime.settings.save(&self.settings_path)?;
        }
        self.settings().await
    }

    pub async fn set_autostart(&self, enabled: bool) -> Result<SettingsDto, AppError> {
        set_autostart(enabled)?;
        self.settings().await
    }

    pub async fn recent_dictations(&self) -> Result<Vec<DictationEntryDto>, AppError> {
        self.history.recent_three().await
    }

    pub async fn copy_dictation(&self, index: u32) -> Result<(), AppError> {
        let entries = self.recent_dictations().await?;
        let entry = entries
            .get(usize::try_from(index).map_err(|_| AppError::invalid("index is too large"))?)
            .ok_or_else(|| AppError::invalid("dictation index is outside the recent list"))?;
        copy_text(&entry.text)
    }

    pub fn model_download_status(&self) -> ModelStatusDto {
        lock_recover(&self.model_status).clone()
    }

    pub fn download_model(self: &Arc<Self>) -> Result<(), AppError> {
        {
            let mut status = lock_recover(&self.model_status);
            if matches!(
                *status,
                ModelStatusDto::Downloading { .. } | ModelStatusDto::Ready
            ) {
                return Ok(());
            }
            if self.model_store.is_ready() {
                *status = ModelStatusDto::Ready;
                return Ok(());
            }
            *status = ModelStatusDto::Downloading { fraction: 0.0 };
        }
        self.refresh_model_menu_without_wait();

        let controller = Arc::clone(self);
        tauri::async_runtime::spawn(async move {
            let result = controller.run_model_download().await;
            controller.finish_model_download(result).await;
        });
        Ok(())
    }

    pub fn open_history_folder(&self) -> Result<(), AppError> {
        open_history_folder(&self.history_path)
    }

    pub async fn update_check(&self) -> Result<UpdateCheckDto, AppError> {
        let dictation_active = {
            let runtime = self.runtime.lock().await;
            runtime
                .coordinator
                .as_ref()
                .is_some_and(|coordinator| coordinator.state() != State::Idle)
        };
        if dictation_active {
            return Err(AppError::busy(
                "Finish the current dictation before installing an update.",
            ));
        }

        crate::obs::log("checking for updates");
        let updater = self
            .app
            .updater()
            .map_err(|error| updater_error("initialize updater", error))?;
        let Some(update) = updater
            .check()
            .await
            .map_err(|error| updater_error("check for updates", error))?
        else {
            crate::obs::log("update check complete: latest version");
            return Ok(UpdateCheckDto {
                available: false,
                message: "You're on the latest version.".to_owned(),
            });
        };

        let version = update.version.clone();
        crate::obs::log(&format!("update {version} available; downloading"));
        let mut downloaded = 0_u64;
        let mut last_percent = None;
        update
            .download_and_install(
                |chunk_size, total_size| {
                    downloaded = downloaded.saturating_add(chunk_size as u64);
                    if let Some(total_size) = total_size.filter(|total| *total > 0) {
                        let percent = downloaded.saturating_mul(100) / total_size;
                        if last_percent != Some(percent) {
                            crate::obs::log(&format!("downloading update {version}: {percent}%"));
                            last_percent = Some(percent);
                        }
                    }
                },
                || crate::obs::log("update download complete; installing"),
            )
            .await
            .map_err(|error| updater_error("download and install update", error))?;

        crate::obs::log("update installed; restarting");
        self.app.restart()
    }

    pub async fn handle_recent_menu(&self, index: usize) {
        let result = self.recent_dictations().await.and_then(|entries| {
            let entry = entries
                .get(index)
                .ok_or_else(|| AppError::invalid("recent dictation no longer exists"))?;
            if entry.text.is_empty() {
                self.open_history_folder()
            } else {
                copy_text(&entry.text)
            }
        });
        let _ = result;
    }

    fn settings_dto(&self, settings: &Settings) -> Result<SettingsDto, AppError> {
        let effective = effective_transcription_mode(
            settings.transcription_mode,
            self.cloud_credentials.is_some(),
        );
        let resolved = settings
            .language
            .unwrap_or_else(|| resolve_system_language(&system_locale()));
        Ok(SettingsDto {
            hotkey_mode: settings.hotkey_mode,
            shortcut: settings.shortcut.clone(),
            transcription_mode: settings.transcription_mode,
            effective_transcription_mode: effective,
            language: settings.language,
            resolved_language: resolved,
            play_sounds: settings.play_sounds,
            autostart_enabled: autostart_enabled()?,
        })
    }

    fn rebuild_locked(&self, runtime: &mut RuntimeState, load_local: bool) -> Result<(), AppError> {
        if runtime
            .coordinator
            .as_ref()
            .is_some_and(|coordinator| coordinator.state() != State::Idle)
        {
            return Ok(());
        }
        let effective = effective_transcription_mode(
            runtime.settings.transcription_mode,
            self.cloud_credentials.is_some(),
        );
        let transcriber = match effective {
            TranscriptionPreference::Cloud => {
                let credentials = self.cloud_credentials.as_ref().ok_or_else(|| {
                    AppError::not_ready("cloud credentials are unavailable in this build")
                })?;
                ActiveTranscriber::Cloud(CloudTranscriber::new(
                    credentials.endpoint.clone(),
                    credentials.key.clone(),
                ))
            }
            TranscriptionPreference::Local if !self.model_store.is_ready() => {
                runtime.coordinator = None;
                runtime.coordinator_mode = None;
                self.set_model_status(ModelStatusDto::Missing);
                return Ok(());
            }
            TranscriptionPreference::Local if !load_local => {
                runtime.coordinator = None;
                runtime.coordinator_mode = None;
                return Ok(());
            }
            TranscriptionPreference::Local => {
                let model_path = self
                    .model_store
                    .files
                    .iter()
                    .find(|file| {
                        Path::new(&file.name)
                            .extension()
                            .is_some_and(|ext| ext == "onnx")
                    })
                    .map(|file| self.model_store.local_path(file))
                    .ok_or_else(|| AppError::not_ready("local model file is unavailable"))?;
                match LocalTranscriber::new(model_path) {
                    Ok(transcriber) => {
                        self.set_model_status(ModelStatusDto::Ready);
                        lock_recover(&self.model_idle).on_loaded();
                        ActiveTranscriber::Local(transcriber)
                    }
                    Err(error) => {
                        let message = format!("Local model could not be loaded: {error}");
                        self.set_model_status(ModelStatusDto::Failed {
                            message: message.clone(),
                        });
                        runtime.coordinator = None;
                        runtime.coordinator_mode = None;
                        return Err(AppError::not_ready(message));
                    }
                }
            }
        };

        if effective == TranscriptionPreference::Cloud {
            lock_recover(&self.model_idle).mark_unloaded();
        }
        let clock: Arc<dyn Clock> = self.clock.clone();
        let mut mic = CpalMic::new(clock);
        if let ActiveTranscriber::Local(local) = &transcriber {
            // The local model runs the recording chunk by chunk while the user is still
            // speaking, so releasing the hotkey only leaves the tail to transcribe.
            let sink = local.clone();
            mic.set_tap(Arc::new(move |samples: &[i16]| sink.feed(samples)));
        }
        runtime.coordinator = Some(Coordinator::new(
            mic,
            transcriber,
            PlatformInserter::new(),
            self.history.clone(),
        ));
        runtime.coordinator_mode = Some(effective);
        Ok(())
    }

    fn apply_pending_mode_locked(&self, runtime: &mut RuntimeState) -> Result<(), AppError> {
        let desired = effective_transcription_mode(
            runtime.settings.transcription_mode,
            self.cloud_credentials.is_some(),
        );
        let idle = runtime
            .coordinator
            .as_ref()
            .is_none_or(|coordinator| coordinator.state() == State::Idle);
        if idle && runtime.coordinator_mode != Some(desired) {
            self.rebuild_locked(runtime, false)?;
        }
        Ok(())
    }

    async fn install_hotkey(self: &Arc<Self>) -> Result<(), AppError> {
        let (mode, shortcut) = {
            let runtime = self.runtime.lock().await;
            (
                hotkey_mode(runtime.settings.hotkey_mode),
                runtime.settings.shortcut.clone(),
            )
        };
        let clock: Arc<dyn Clock> = self.clock.clone();
        let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
        let command_tx = event_tx.clone();
        crate::obs::log(&format!(
            "install_hotkey mode={mode:?} shortcut={shortcut:?}"
        ));
        let hotkey = HotkeyAdapter::spawn(
            mode,
            shortcut,
            clock,
            Arc::clone(&self.recording),
            move |command| {
                crate::obs::log(&format!("hook command: {command:?}"));
                let _ = command_tx.send(HotkeyEvent::Command(command));
            },
            move || {
                let _ = event_tx.send(HotkeyEvent::Cancel);
            },
        )
        .map_err(|error| AppError::platform(error.to_string()))?;
        *lock_recover(&self.hotkey) = Some(hotkey);

        let controller = Arc::downgrade(self);
        tauri::async_runtime::spawn(async move {
            while let Some(event) = event_rx.recv().await {
                let Some(controller) = controller.upgrade() else {
                    break;
                };
                match event {
                    HotkeyEvent::Command(Command::Start) => {
                        crate::obs::log("hotkey Start -> begin");
                        match controller.begin().await {
                            Ok(()) => crate::obs::log("begin ok (recording)"),
                            Err(e) => crate::obs::log(&format!("begin err: {e:?}")),
                        }
                    }
                    HotkeyEvent::Command(Command::Stop) => {
                        crate::obs::log("hotkey Stop -> end");
                        match controller.end().await {
                            Ok(o) => crate::obs::log(&format!("end ok: {o:?}")),
                            Err(e) => crate::obs::log(&format!("end err: {e:?}")),
                        }
                    }
                    HotkeyEvent::Command(Command::None) => {}
                    HotkeyEvent::Cancel => {
                        crate::obs::log("hotkey Cancel");
                        let _ = controller.cancel().await;
                    }
                }
            }
        });
        Ok(())
    }

    fn start_model_idle_monitor(self: &Arc<Self>) {
        let controller = Arc::downgrade(self);
        tauri::async_runtime::spawn(async move {
            loop {
                tokio::time::sleep(MODEL_IDLE_POLL).await;
                let Some(controller) = controller.upgrade() else {
                    break;
                };
                controller.unload_idle_model().await;
            }
        });
    }

    async fn unload_idle_model(&self) {
        let mut runtime = self.runtime.lock().await;
        let local_is_idle = runtime.coordinator_mode == Some(TranscriptionPreference::Local)
            && runtime
                .coordinator
                .as_ref()
                .is_some_and(|coordinator| coordinator.state() == State::Idle);
        if local_is_idle && lock_recover(&self.model_idle).unload_if_idle(self.clock.as_ref()) {
            runtime.coordinator = None;
            runtime.coordinator_mode = None;
        }
    }

    async fn run_model_download(&self) -> Result<(), String> {
        let files = self
            .model_store
            .missing_files()
            .into_iter()
            .cloned()
            .collect::<Vec<_>>();
        let total = files.iter().map(|file| file.size).sum::<u64>().max(1);
        let mut completed = 0_u64;
        let downloader = ModelDownloader::new();
        for file in files {
            downloader
                .download(&file, &self.model_store)
                .await
                .map_err(|error| error.to_string())?;
            completed = completed.saturating_add(file.size);
            self.set_model_status(ModelStatusDto::Downloading {
                fraction: (completed as f64 / total as f64).clamp(0.0, 1.0),
            });
            self.refresh_model_menu().await;
        }
        if self.model_store.is_ready() {
            Ok(())
        } else {
            Err("Model download did not complete every required file.".to_owned())
        }
    }

    async fn finish_model_download(&self, result: Result<(), String>) {
        match result {
            Ok(()) => self.set_model_status(ModelStatusDto::Ready),
            Err(message) => self.set_model_status(ModelStatusDto::Failed { message }),
        }
        self.refresh_model_menu().await;
    }

    fn set_model_status(&self, status: ModelStatusDto) {
        *lock_recover(&self.model_status) = status;
    }

    async fn refresh_tray(&self) {
        self.tray.set_phase(&self.app, TrayPhase::Idle);
        self.refresh_recent().await;
        self.refresh_model_menu().await;
    }

    async fn refresh_recent(&self) {
        if let Ok(entries) = self.recent_dictations().await {
            self.tray.set_recent(&entries);
        }
    }

    async fn refresh_model_menu(&self) {
        let effective = {
            let runtime = self.runtime.lock().await;
            effective_transcription_mode(
                runtime.settings.transcription_mode,
                self.cloud_credentials.is_some(),
            )
        };
        self.tray
            .set_model(&self.model_download_status(), effective);
    }

    fn refresh_model_menu_without_wait(self: &Arc<Self>) {
        let controller = Arc::clone(self);
        tauri::async_runtime::spawn(async move {
            controller.refresh_model_menu().await;
        });
    }
}

fn history_dto(entry: HistoryEntry) -> Result<DictationEntryDto, AppError> {
    let seconds = entry
        .recorded_at
        .duration_since(UNIX_EPOCH)
        .map_err(|error| AppError::internal(error.to_string()))?
        .as_secs();
    Ok(DictationEntryDto {
        text: entry.text,
        recorded_at: i64::try_from(seconds)
            .map_err(|_| AppError::internal("history timestamp is out of range"))?,
    })
}

fn data_root() -> PathBuf {
    dirs::data_dir().unwrap_or_default().join("sezish")
}

fn lock_recover<T>(mutex: &SyncMutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn baked_cloud_credentials() -> Option<CloudCredentials> {
    let endpoint = env!("SEZISH_BAKED_CLOUD_ENDPOINT").trim();
    let key = env!("SEZISH_BAKED_CLOUD_KEY").trim();
    if endpoint.is_empty()
        || key.is_empty()
        || !(endpoint.starts_with("https://") || endpoint.starts_with("http://"))
    {
        return None;
    }
    Some(CloudCredentials {
        endpoint: endpoint.to_owned(),
        key: key.to_owned(),
    })
}

fn hotkey_mode(mode: HotkeyPreference) -> HotkeyMode {
    match mode {
        HotkeyPreference::Hold => HotkeyMode::Hold,
        HotkeyPreference::Toggle => HotkeyMode::Toggle,
    }
}

fn updater_error(step: &str, error: impl std::fmt::Display) -> AppError {
    let message = format!("Could not {step}: {error}");
    crate::obs::log(&message);
    AppError::platform(message)
}
