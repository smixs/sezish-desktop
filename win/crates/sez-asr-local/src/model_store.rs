use crate::{Vocab, VocabError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The on-device recognition models the user can pick between. Each one is a
/// self-contained set of files: exactly one `.onnx` plus its token table.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AsrModel {
    /// Russian, Uzbek, Kazakh, Kyrgyz. Character-level output, no punctuation.
    /// The model every install already has, hence the default.
    #[default]
    Multilingual,
    /// Russian and English with punctuation, casing and normalized numbers.
    #[serde(rename = "ru-en-punctuated")]
    RuEnPunctuated,
}

impl AsrModel {
    /// Stable identifier used in `settings.json`, the IPC and the log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Multilingual => "multilingual",
            Self::RuEnPunctuated => "ru-en-punctuated",
        }
    }

    /// Files that make up the bundle, with the exact byte sizes to validate against.
    pub fn files(self) -> Vec<ModelFile> {
        match self {
            Self::Multilingual => vec![
                ModelFile {
                    name: "multilingual_ctc.int8.onnx".to_owned(),
                    size: 224_762_204,
                },
                ModelFile {
                    name: "multilingual_vocab.txt".to_owned(),
                    size: 393,
                },
                ModelFile {
                    name: "config.json".to_owned(),
                    size: 152,
                },
            ],
            // No config.json here: nothing reads it, and the multilingual set already
            // owns that file name in the shared directory.
            Self::RuEnPunctuated => vec![
                ModelFile {
                    name: "v3_e2e_ctc.int8.onnx".to_owned(),
                    size: 224_893_347,
                },
                ModelFile {
                    name: "v3_e2e_ctc_vocab.txt".to_owned(),
                    size: 2_007,
                },
            ],
        }
    }

    /// Where the files are fetched from; the file name is appended.
    pub fn remote_base(self) -> &'static str {
        match self {
            Self::Multilingual => ModelStore::REMOTE_BASE,
            Self::RuEnPunctuated => "https://dl.sezi.sh/models/",
        }
    }

    /// The token table the weights were trained with. Only the multilingual bundle
    /// predates the downloaded vocab, so only it falls back to the compiled-in copy.
    pub fn vocab(self, path: &Path) -> Result<Vocab, VocabError> {
        match Vocab::from_file(path) {
            Ok(vocab) => Ok(vocab),
            Err(_) if self == Self::Multilingual => Vocab::bundled(),
            Err(error) => Err(error),
        }
    }
}

/// One file in the downloaded model bundle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelFile {
    /// Remote and local file name.
    pub name: String,
    /// Exact expected byte size.
    pub size: u64,
}

/// Paths and expected files for the downloaded model bundle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelStore {
    /// Directory containing downloaded files.
    pub directory: PathBuf,
    /// Files required for a complete bundle.
    pub files: Vec<ModelFile>,
    /// Remote endpoint prefix the files are fetched from.
    pub remote_base: String,
}

impl ModelStore {
    /// Remote endpoint prefix for model bundle files.
    pub const REMOTE_BASE: &'static str =
        "https://huggingface.co/istupakov/gigaam-multilingual-ctc-onnx/resolve/main/";

    /// Returns the required model bundle files and exact byte sizes.
    pub fn default_files() -> Vec<ModelFile> {
        AsrModel::default().files()
    }

    /// Creates a model store with optional path and file-list test seams.
    pub fn new(root: Option<PathBuf>, files: Option<Vec<ModelFile>>) -> Self {
        Self {
            directory: root.unwrap_or_else(Self::default_directory),
            files: files.unwrap_or_else(Self::default_files),
            remote_base: Self::REMOTE_BASE.to_owned(),
        }
    }

    /// Creates the store for one model. Both models live in the same directory:
    /// their file names do not collide, so a downloaded bundle survives switching.
    pub fn for_model(model: AsrModel, root: Option<PathBuf>) -> Self {
        Self {
            directory: root.unwrap_or_else(Self::default_directory),
            files: model.files(),
            remote_base: model.remote_base().to_owned(),
        }
    }

    /// Path of the bundle's acoustic model.
    pub fn onnx_path(&self) -> Option<PathBuf> {
        self.path_ending_with(".onnx")
    }

    /// Path of the bundle's token table.
    pub fn vocab_path(&self) -> Option<PathBuf> {
        self.path_ending_with("vocab.txt")
    }

    fn path_ending_with(&self, suffix: &str) -> Option<PathBuf> {
        self.files
            .iter()
            .find(|file| file.name.ends_with(suffix))
            .map(|file| self.local_path(file))
    }

    /// Returns the per-user default model directory.
    pub fn default_directory() -> PathBuf {
        dirs::data_dir()
            .unwrap_or_default()
            .join("sezish")
            .join(".models")
    }

    /// Returns the on-disk path for a model file.
    pub fn local_path(&self, file: &ModelFile) -> PathBuf {
        self.directory.join(&file.name)
    }

    /// Returns the remote URL for a model file.
    pub fn remote_url(&self, file: &ModelFile) -> String {
        format!("{base}{name}", base = self.remote_base, name = file.name)
    }

    /// Reports whether a model file exists at exactly the expected size.
    pub fn is_complete(&self, file: &ModelFile) -> bool {
        std::fs::metadata(self.local_path(file))
            .map(|metadata| metadata.len() == file.size)
            .unwrap_or(false)
    }

    /// Returns incomplete model files in bundle order.
    pub fn missing_files(&self) -> Vec<&ModelFile> {
        self.files
            .iter()
            .filter(|file| !self.is_complete(file))
            .collect()
    }

    /// Reports whether every model bundle file is complete.
    pub fn is_ready(&self) -> bool {
        self.missing_files().is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::{AsrModel, ModelFile, ModelStore};
    use std::fs;
    use std::path::PathBuf;
    use tempfile::TempDir;

    #[test]
    fn default_files_match_reference_bundle() {
        assert_eq!(
            ModelStore::default_files(),
            vec![
                ModelFile {
                    name: "multilingual_ctc.int8.onnx".to_owned(),
                    size: 224_762_204,
                },
                ModelFile {
                    name: "multilingual_vocab.txt".to_owned(),
                    size: 393,
                },
                ModelFile {
                    name: "config.json".to_owned(),
                    size: 152,
                },
            ]
        );
    }

    /// Byte sizes and names are the contract with the server: a wrong one makes every
    /// download fail on the size check. These match the macOS `AsrModel.swift`.
    #[test]
    fn punctuated_bundle_matches_the_files_on_the_server() {
        let store = ModelStore::for_model(AsrModel::RuEnPunctuated, Some(PathBuf::from("/models")));

        assert_eq!(
            store.files,
            vec![
                ModelFile {
                    name: "v3_e2e_ctc.int8.onnx".to_owned(),
                    size: 224_893_347,
                },
                ModelFile {
                    name: "v3_e2e_ctc_vocab.txt".to_owned(),
                    size: 2_007,
                },
            ]
        );
        assert_eq!(
            store.remote_url(&store.files[0]),
            "https://dl.sezi.sh/models/v3_e2e_ctc.int8.onnx"
        );
        assert_eq!(
            store.onnx_path(),
            Some(PathBuf::from("/models/v3_e2e_ctc.int8.onnx"))
        );
        assert_eq!(
            store.vocab_path(),
            Some(PathBuf::from("/models/v3_e2e_ctc_vocab.txt"))
        );
    }

    #[test]
    fn injected_root_is_used_exactly_for_local_and_remote_paths() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let file = ModelFile {
            name: "fixture.bin".to_owned(),
            size: 4,
        };
        let store = ModelStore::new(
            Some(directory.path().to_path_buf()),
            Some(vec![file.clone()]),
        );

        assert_eq!(store.directory, directory.path());
        assert_eq!(
            store.local_path(&file),
            directory.path().join("fixture.bin")
        );
        assert_eq!(
            store.remote_url(&file),
            format!("{}fixture.bin", ModelStore::REMOTE_BASE)
        );
    }

    #[test]
    fn completeness_uses_exact_on_disk_size() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let complete = ModelFile {
            name: "complete.bin".to_owned(),
            size: 4,
        };
        let wrong_size = ModelFile {
            name: "wrong.bin".to_owned(),
            size: 4,
        };
        let missing = ModelFile {
            name: "missing.bin".to_owned(),
            size: 1,
        };
        fs::write(directory.path().join(&complete.name), b"done")
            .expect("complete fixture should be written");
        fs::write(directory.path().join(&wrong_size.name), b"bad")
            .expect("wrong-size fixture should be written");
        let store = ModelStore::new(
            Some(directory.path().to_path_buf()),
            Some(vec![complete.clone(), wrong_size.clone(), missing.clone()]),
        );

        assert!(store.is_complete(&complete));
        assert!(!store.is_complete(&wrong_size));
        assert!(!store.is_complete(&missing));
        assert_eq!(store.missing_files(), vec![&wrong_size, &missing]);
        assert!(!store.is_ready());
    }

    #[test]
    fn ready_when_all_files_have_exact_sizes() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let file = ModelFile {
            name: "complete.bin".to_owned(),
            size: 4,
        };
        fs::write(directory.path().join(&file.name), b"done")
            .expect("complete fixture should be written");
        let store = ModelStore::new(Some(directory.path().to_path_buf()), Some(vec![file]));

        assert!(store.is_ready());
    }
}
