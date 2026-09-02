//! Local transcription support.

pub mod chunker;
mod ctc;
mod downloader;
#[cfg(feature = "local-inference")]
mod inference;
mod model_store;
pub mod stream;

/// Where crate diagnostics go. The app installs its own file log here; without it
/// the timing lines are dropped, so nothing else in the crate depends on logging.
#[cfg(feature = "local-inference")]
static LOGGER: std::sync::OnceLock<Logger> = std::sync::OnceLock::new();

#[cfg(feature = "local-inference")]
type Logger = Box<dyn Fn(&str) + Send + Sync>;

/// Routes crate diagnostics to the host log. The first call wins.
#[cfg(feature = "local-inference")]
pub fn set_logger(logger: impl Fn(&str) + Send + Sync + 'static) {
    let _ = LOGGER.set(Box::new(logger));
}

#[cfg(feature = "local-inference")]
pub(crate) fn log(message: &str) {
    if let Some(logger) = LOGGER.get() {
        logger(message);
    }
}

pub use ctc::{CtcDecoder, Vocab, VocabError};
pub use downloader::{ModelDownloadError, ModelDownloader};
#[cfg(feature = "local-inference")]
pub use inference::{LocalTranscriber, LocalTranscriberError};
pub use model_store::{ModelFile, ModelStore};
