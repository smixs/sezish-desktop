use std::path::PathBuf;

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
}

impl ModelStore {
    /// Remote endpoint prefix for model bundle files.
    pub const REMOTE_BASE: &'static str =
        "https://huggingface.co/istupakov/gigaam-multilingual-ctc-onnx/resolve/main/";

    /// Returns the required model bundle files and exact byte sizes.
    pub fn default_files() -> Vec<ModelFile> {
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
    }

    /// Creates a model store with optional path and file-list test seams.
    pub fn new(root: Option<PathBuf>, files: Option<Vec<ModelFile>>) -> Self {
        Self {
            directory: root.unwrap_or_else(Self::default_directory),
            files: files.unwrap_or_else(Self::default_files),
        }
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
        format!("{}{name}", Self::REMOTE_BASE, name = file.name)
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
    use super::{ModelFile, ModelStore};
    use std::fs;
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
