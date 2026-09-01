//! Local transcription support.

pub mod chunker;
mod ctc;
mod downloader;
#[cfg(feature = "local-inference")]
mod inference;
mod model_store;
pub mod stream;

pub use ctc::{CtcDecoder, Vocab, VocabError};
pub use downloader::{ModelDownloadError, ModelDownloader};
#[cfg(feature = "local-inference")]
pub use inference::{LocalTranscriber, LocalTranscriberError};
pub use model_store::{ModelFile, ModelStore};
