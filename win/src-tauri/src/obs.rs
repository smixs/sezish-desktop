//! Minimal file logging for field diagnostics.
//!
//! Writes to `%APPDATA%\sezish\sezish.log` (appended). Enough to trace the
//! dictation pipeline (hotkey edge → begin → transcribe → insert) on a user's
//! machine without a debugger. Deliberately dependency-free and best-effort:
//! any logging failure is swallowed so it can never affect dictation.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

static LOG_PATH: OnceLock<Option<PathBuf>> = OnceLock::new();

fn log_path() -> Option<PathBuf> {
    LOG_PATH
        .get_or_init(|| {
            let base = std::env::var_os("APPDATA").map(PathBuf::from)?;
            let dir = base.join("sezish");
            std::fs::create_dir_all(&dir).ok()?;
            Some(dir.join("sezish.log"))
        })
        .clone()
}

/// Appends one timestamped line to the log. Never panics.
pub fn log(message: &str) {
    let Some(path) = log_path() else { return };
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "[{secs}] {message}");
    }
}
