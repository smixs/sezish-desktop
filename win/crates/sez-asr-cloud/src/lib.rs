use reqwest::Client;
use serde::Deserialize;
use sez_core::{SezError, Transcriber};
use std::{sync::Arc, time::Duration};
use thiserror::Error;
use tokio::runtime::Handle;

const WARMUP_TIMEOUT: Duration = Duration::from_secs(15);
const ERROR_BODY_LIMIT: usize = 200;

/// Detailed failures returned by [`CloudTranscriber::transcribe`].
#[derive(Debug, Error)]
pub enum CloudTranscriberError {
    /// The endpoint returned a non-success HTTP status.
    #[error("cloud endpoint returned HTTP {status}: {body_snippet}")]
    HttpStatus {
        /// Numeric HTTP status code.
        status: u16,
        /// Lossy UTF-8 rendering of the first 200 response-body bytes.
        body_snippet: String,
    },
    /// The HTTP request or response body transfer failed.
    #[error("cloud request failed: {0}")]
    Request(#[from] reqwest::Error),
    /// A successful response did not contain the expected JSON shape.
    #[error("cloud response was invalid JSON: {0}")]
    Decode(#[from] serde_json::Error),
}

impl From<CloudTranscriberError> for SezError {
    fn from(error: CloudTranscriberError) -> Self {
        match error {
            CloudTranscriberError::Request(source) if source.is_timeout() => Self::Timeout,
            other => Self::Other(other.to_string()),
        }
    }
}

struct Inner {
    client: Client,
    endpoint: String,
    api_key: String,
}

/// REST-backed cloud transcription adapter.
#[derive(Clone)]
pub struct CloudTranscriber {
    inner: Arc<Inner>,
    runtime: Handle,
}

impl CloudTranscriber {
    /// Creates an adapter that posts to `endpoint` exactly as supplied.
    ///
    /// # Panics
    ///
    /// Panics when called outside a Tokio runtime. The captured runtime handle
    /// is required for the synchronous, fire-and-forget [`Transcriber::warmup`].
    pub fn new(endpoint: impl Into<String>, api_key: impl Into<String>) -> Self {
        let runtime = Handle::current();
        Self {
            inner: Arc::new(Inner {
                client: Client::new(),
                endpoint: endpoint.into(),
                api_key: api_key.into(),
            }),
            runtime,
        }
    }

    /// Transcribes PCM16 mono 16 kHz samples via the configured endpoint.
    pub async fn transcribe(&self, samples: &[i16]) -> Result<String, CloudTranscriberError> {
        if samples.is_empty() {
            return Ok(String::new());
        }

        let wav = sez_core::wav::encode_pcm16_mono_16k(samples);
        let response = self
            .inner
            .client
            .post(&self.inner.endpoint)
            .header("X-API-Key", &self.inner.api_key)
            .body(wav)
            .timeout(timeout_for_sample_count(samples.len()))
            .send()
            .await?;
        let status = response.status();
        let body = response.bytes().await?;

        if !status.is_success() {
            let snippet = &body[..body.len().min(ERROR_BODY_LIMIT)];
            return Err(CloudTranscriberError::HttpStatus {
                status: status.as_u16(),
                body_snippet: String::from_utf8_lossy(snippet).into_owned(),
            });
        }

        #[derive(Deserialize)]
        struct Reply {
            text: String,
        }

        Ok(serde_json::from_slice::<Reply>(&body)?.text)
    }

    async fn warmup_request(&self) {
        let _ = self
            .inner
            .client
            .get(&self.inner.endpoint)
            .timeout(WARMUP_TIMEOUT)
            .send()
            .await;
    }
}

#[async_trait::async_trait]
impl Transcriber for CloudTranscriber {
    fn warmup(&self) {
        let transcriber = self.clone();
        self.runtime.spawn(async move {
            transcriber.warmup_request().await;
        });
    }

    async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError> {
        CloudTranscriber::transcribe(self, samples)
            .await
            .map_err(Into::into)
    }
}

/// Returns the cloud request timeout for a PCM16 mono 16 kHz sample count.
pub fn timeout_for_sample_count(count: usize) -> Duration {
    let audio_seconds = count as f64 / sez_core::wav::SAMPLE_RATE as f64;
    Duration::from_secs_f64((60.0 + 0.35 * audio_seconds).max(120.0))
}

#[cfg(test)]
mod tests {
    use super::{timeout_for_sample_count, CloudTranscriber, CloudTranscriberError};
    use httpmock::prelude::*;
    use sez_core::Transcriber;
    use std::time::Duration;

    #[tokio::test]
    async fn transcribe_posts_exact_wav_to_root_with_api_key() {
        let server = MockServer::start_async().await;
        let samples = [0x1234, -2, 0];
        let expected_wav: Vec<u8> = vec![
            b'R', b'I', b'F', b'F', 42, 0, 0, 0, b'W', b'A', b'V', b'E', b'f', b'm', b't', b' ',
            16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0, 2, 0, 16, 0, b'd', b'a',
            b't', b'a', 6, 0, 0, 0, 0x34, 0x12, 0xfe, 0xff, 0, 0,
        ];
        assert_eq!(&expected_wav[0..4], b"RIFF");
        assert_eq!(&expected_wav[8..12], b"WAVE");
        assert_eq!(
            u32::from_le_bytes(expected_wav[40..44].try_into().unwrap()) as usize / 2,
            samples.len()
        );

        let post = server
            .mock_async(move |when, then| {
                when.method(POST)
                    .path("/")
                    .header("X-API-Key", "secret")
                    .is_true(move |request| request.body_ref() == expected_wav.as_slice());
                then.status(200)
                    .header("content-type", "application/json")
                    .body(r#"{"text":"salom"}"#);
            })
            .await;
        let transcriber = CloudTranscriber::new(server.url("/"), "secret");

        let text = transcriber.transcribe(&samples).await.unwrap();

        assert_eq!(text, "salom");
        post.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn empty_samples_short_circuit_without_network_request() {
        let server = MockServer::start_async().await;
        let post = server
            .mock_async(|when, then| {
                when.method(POST).path("/");
                then.status(500);
            })
            .await;
        let transcriber = CloudTranscriber::new(server.url("/"), "secret");

        let text = transcriber.transcribe(&[]).await.unwrap();

        assert_eq!(text, "");
        post.assert_calls_async(0).await;
    }

    #[tokio::test]
    async fn warmup_request_gets_root_exactly_once() {
        let server = MockServer::start_async().await;
        let get = server
            .mock_async(|when, then| {
                when.method(GET).path("/");
                then.status(200).body(r#"{"ok":true}"#);
            })
            .await;
        let transcriber = CloudTranscriber::new(server.url("/"), "secret");

        transcriber.warmup_request().await;

        get.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn non_success_response_preserves_status_and_truncated_body() {
        let server = MockServer::start_async().await;
        let expected = "permission denied";
        let response_body = format!("{expected}{}", "x".repeat(300));
        let response = server
            .mock_async(|when, then| {
                when.method(POST).path("/");
                then.status(401).body(response_body);
            })
            .await;
        let transcriber = CloudTranscriber::new(server.url("/"), "wrong-key");

        let error = transcriber.transcribe(&[1; 64]).await.unwrap_err();

        match error {
            CloudTranscriberError::HttpStatus {
                status,
                body_snippet,
            } => {
                assert_eq!(status, 401);
                assert!(body_snippet.contains(expected));
                assert_eq!(body_snippet.len(), 200);
            }
            other => panic!("expected HTTP status error, got {other:?}"),
        }
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn empty_text_is_a_successful_transcript() {
        let server = MockServer::start_async().await;
        let response = server
            .mock_async(|when, then| {
                when.method(POST).path("/");
                then.status(200)
                    .header("content-type", "application/json")
                    .body(r#"{"text":""}"#);
            })
            .await;
        let transcriber = CloudTranscriber::new(server.url("/"), "secret");

        let text = transcriber.transcribe(&[1; 64]).await.unwrap();

        assert_eq!(text, "");
        response.assert_calls_async(1).await;
    }

    #[test]
    fn timeout_scales_from_120_second_floor() {
        assert_eq!(timeout_for_sample_count(0), Duration::from_secs(120));
        assert_eq!(
            timeout_for_sample_count(3_200_000),
            Duration::from_secs(130)
        );
    }

    #[tokio::test]
    async fn extra_response_fields_are_ignored() {
        let server = MockServer::start_async().await;
        let response = server
            .mock_async(|when, then| {
                when.method(POST).path("/");
                then.status(200)
                    .header("content-type", "application/json")
                    .body(r#"{"text":"salom","audio_seconds":1.5,"elapsed":0.2,"rtf":7.5}"#);
            })
            .await;
        let transcriber = CloudTranscriber::new(server.url("/"), "secret");

        let text = transcriber.transcribe(&[1; 64]).await.unwrap();

        assert_eq!(text, "salom");
        response.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn warmup_wrapper_returns_immediately() {
        let transcriber = CloudTranscriber::new("http://127.0.0.1:9", "secret");

        Transcriber::warmup(&transcriber);

        assert_eq!(2 + 2, 4);
    }
}
