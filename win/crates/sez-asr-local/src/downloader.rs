use crate::{ModelFile, ModelStore};
use reqwest::{header::RANGE, Client, StatusCode};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};
use thiserror::Error;

/// Failures from downloading a model bundle file.
#[derive(Debug, Error)]
pub enum ModelDownloadError {
    /// The server returned a status other than 200 or 206.
    #[error("download returned HTTP {0}")]
    HttpStatus(u16),
    /// The completed partial file had the wrong byte size.
    #[error("download size mismatch: expected {expected}, got {actual}")]
    SizeMismatch {
        /// Expected byte size.
        expected: u64,
        /// Actual byte size.
        actual: u64,
    },
    /// The HTTP request or body transfer failed.
    #[error(transparent)]
    Request(#[from] reqwest::Error),
    /// A local filesystem operation failed.
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Resumable downloader for model bundle files.
pub struct ModelDownloader {
    client: Client,
}

impl ModelDownloader {
    /// Creates a downloader with a reusable HTTP client.
    pub fn new() -> Self {
        Self {
            client: Client::new(),
        }
    }

    /// Downloads all incomplete files in bundle order.
    pub async fn download_missing(&self, store: &ModelStore) -> Result<(), ModelDownloadError> {
        for file in store.missing_files() {
            self.download(file, store).await?;
        }
        Ok(())
    }

    /// Downloads one model file into its store path.
    pub async fn download(
        &self,
        file: &ModelFile,
        store: &ModelStore,
    ) -> Result<(), ModelDownloadError> {
        self.download_to(&store.remote_url(file), &store.local_path(file), file.size)
            .await
    }

    pub(crate) async fn download_to(
        &self,
        remote_url: &str,
        final_path: &Path,
        expected_size: u64,
    ) -> Result<(), ModelDownloadError> {
        if let Some(parent) = final_path.parent() {
            fs::create_dir_all(parent)?;
        }

        let partial_path = partial_path(final_path);
        let existing = fs::metadata(&partial_path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        let mut request = self.client.get(remote_url);
        if existing > 0 {
            request = request.header(RANGE, format!("bytes={existing}-"));
        }

        let mut response = request.send().await?;
        let appending = match response.status() {
            StatusCode::PARTIAL_CONTENT => true,
            StatusCode::OK => false,
            status => return Err(ModelDownloadError::HttpStatus(status.as_u16())),
        };
        let mut partial = OpenOptions::new()
            .create(true)
            .write(true)
            .append(appending)
            .truncate(!appending)
            .open(&partial_path)?;

        while let Some(chunk) = response.chunk().await? {
            partial.write_all(&chunk)?;
        }
        partial.flush()?;
        drop(partial);

        let actual = fs::metadata(&partial_path)?.len();
        if actual != expected_size {
            let _ = fs::remove_file(&partial_path);
            return Err(ModelDownloadError::SizeMismatch {
                expected: expected_size,
                actual,
            });
        }

        if final_path.exists() {
            fs::remove_file(final_path)?;
        }
        fs::rename(partial_path, final_path)?;
        Ok(())
    }
}

fn partial_path(final_path: &Path) -> PathBuf {
    let mut path = final_path.as_os_str().to_os_string();
    path.push(".part");
    path.into()
}

impl Default for ModelDownloader {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::{ModelDownloadError, ModelDownloader};
    use httpmock::prelude::*;
    use std::fs;
    use std::path::{Path, PathBuf};
    use tempfile::TempDir;

    fn part_path(final_path: &Path) -> PathBuf {
        PathBuf::from(format!("{}.part", final_path.display()))
    }

    #[tokio::test]
    async fn partial_file_resumes_with_exact_range_and_appends_206_body() {
        let server = MockServer::start_async().await;
        let directory = TempDir::new().expect("temporary directory should be created");
        let final_path = directory.path().join("bundle.bin");
        let partial_path = part_path(&final_path);
        fs::write(&partial_path, b"abc").expect("partial fixture should be written");
        let response = server
            .mock_async(|when, then| {
                when.method(GET)
                    .path("/bundle.bin")
                    .header("range", "bytes=3-");
                then.status(206).body("def");
            })
            .await;

        ModelDownloader::new()
            .download_to(&server.url("/bundle.bin"), &final_path, 6)
            .await
            .expect("resume should succeed");

        assert_eq!(
            fs::read(&final_path).expect("final file should be readable"),
            b"abcdef"
        );
        assert!(!partial_path.exists());
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn stale_partial_is_truncated_when_server_ignores_range_with_200() {
        let server = MockServer::start_async().await;
        let directory = TempDir::new().expect("temporary directory should be created");
        let final_path = directory.path().join("bundle.bin");
        let partial_path = part_path(&final_path);
        fs::write(&partial_path, b"stale-prefix").expect("partial fixture should be written");
        let response = server
            .mock_async(|when, then| {
                when.method(GET)
                    .path("/bundle.bin")
                    .header("range", "bytes=12-");
                then.status(200).body("fresh");
            })
            .await;

        ModelDownloader::new()
            .download_to(&server.url("/bundle.bin"), &final_path, 5)
            .await
            .expect("restart should succeed");

        assert_eq!(
            fs::read(&final_path).expect("final file should be readable"),
            b"fresh"
        );
        assert!(!partial_path.exists());
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn unexpected_http_status_preserves_partial_and_creates_no_final_file() {
        let server = MockServer::start_async().await;
        let directory = TempDir::new().expect("temporary directory should be created");
        let final_path = directory.path().join("bundle.bin");
        let partial_path = part_path(&final_path);
        fs::write(&partial_path, b"keep").expect("partial fixture should be written");
        let response = server
            .mock_async(|when, then| {
                when.method(GET)
                    .path("/bundle.bin")
                    .header("range", "bytes=4-");
                then.status(404);
            })
            .await;

        let error = ModelDownloader::new()
            .download_to(&server.url("/bundle.bin"), &final_path, 8)
            .await
            .expect_err("unexpected status should fail");

        assert!(matches!(error, ModelDownloadError::HttpStatus(404)));
        assert_eq!(
            fs::read(&partial_path).expect("partial file should remain readable"),
            b"keep"
        );
        assert!(!final_path.exists());
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn size_mismatch_deletes_partial_and_creates_no_final_file() {
        let server = MockServer::start_async().await;
        let directory = TempDir::new().expect("temporary directory should be created");
        let final_path = directory.path().join("bundle.bin");
        let partial_path = part_path(&final_path);
        let response = server
            .mock_async(|when, then| {
                when.method(GET).path("/bundle.bin");
                then.status(200).body("short");
            })
            .await;

        let error = ModelDownloader::new()
            .download_to(&server.url("/bundle.bin"), &final_path, 8)
            .await
            .expect_err("wrong-sized response should fail");

        assert!(matches!(
            error,
            ModelDownloadError::SizeMismatch {
                expected: 8,
                actual: 5
            }
        ));
        assert!(!partial_path.exists());
        assert!(!final_path.exists());
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn full_download_atomically_renames_completed_partial() {
        let server = MockServer::start_async().await;
        let directory = TempDir::new().expect("temporary directory should be created");
        let final_path = directory.path().join("nested").join("bundle.bin");
        let partial_path = part_path(&final_path);
        let response = server
            .mock_async(|when, then| {
                when.method(GET).path("/bundle.bin");
                then.status(200).body("complete");
            })
            .await;

        ModelDownloader::new()
            .download_to(&server.url("/bundle.bin"), &final_path, 8)
            .await
            .expect("full download should succeed");

        assert_eq!(
            fs::read(&final_path).expect("final file should be readable"),
            b"complete"
        );
        assert!(!partial_path.exists());
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn kill_and_rerun_resumes_manually_flushed_prefix_byte_for_byte() {
        let server = MockServer::start_async().await;
        let directory = TempDir::new().expect("temporary directory should be created");
        let final_path = directory.path().join("bundle.bin");
        let partial_path = part_path(&final_path);
        fs::write(&partial_path, b"killed-").expect("killed-run prefix should be written directly");
        let response = server
            .mock_async(|when, then| {
                when.method(GET)
                    .path("/bundle.bin")
                    .header("range", "bytes=7-");
                then.status(206).body("then-resumed");
            })
            .await;

        ModelDownloader::new()
            .download_to(&server.url("/bundle.bin"), &final_path, 19)
            .await
            .expect("rerun should resume");

        assert_eq!(
            fs::read(&final_path).expect("final file should be readable"),
            b"killed-then-resumed"
        );
        assert!(!partial_path.exists());
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn empty_start_sends_no_range_header() {
        let server = MockServer::start_async().await;
        let directory = TempDir::new().expect("temporary directory should be created");
        let final_path = directory.path().join("bundle.bin");
        let response = server
            .mock_async(|when, then| {
                when.method(GET).path("/bundle.bin").header_missing("range");
                then.status(200).body("fresh");
            })
            .await;

        ModelDownloader::new()
            .download_to(&server.url("/bundle.bin"), &final_path, 5)
            .await
            .expect("empty-start download should succeed");

        response.assert_calls_async(1).await;
    }
}
