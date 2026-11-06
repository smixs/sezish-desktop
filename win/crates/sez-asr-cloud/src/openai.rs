//! Dictation over OpenAI's `/v1/audio/transcriptions` on the user's own key
//! (macOS `OpenAITranscriber.swift`). The finished take goes up once as a
//! 16 kHz 16-bit WAV; a minute of speech is under 2 MB of the 25 allowed.

use reqwest::Client;
use serde::Deserialize;
use sez_core::{SezError, Transcriber};
use thiserror::Error;

pub const ENDPOINT: &str = "https://api.openai.com/v1/audio/transcriptions";

#[derive(Debug, Error)]
pub enum OpenAiError {
    #[error("OpenAI ответил {code}: {message}")]
    BadResponse { code: u16, message: String },
    #[error("OpenAI request failed: {0}")]
    Request(#[from] reqwest::Error),
    #[error("OpenAI response was invalid JSON: {0}")]
    Decode(#[from] serde_json::Error),
}

impl From<OpenAiError> for SezError {
    fn from(error: OpenAiError) -> Self {
        match error {
            OpenAiError::Request(source) if source.is_timeout() => Self::Timeout,
            other => Self::Other(other.to_string()),
        }
    }
}

#[derive(Clone)]
pub struct OpenAiTranscriber {
    client: Client,
    endpoint: String,
    api_key: String,
    model: String,
}

impl OpenAiTranscriber {
    pub fn new(api_key: impl Into<String>, model: impl Into<String>) -> Self {
        Self::with_endpoint(ENDPOINT, api_key, model)
    }

    pub fn with_endpoint(
        endpoint: impl Into<String>,
        api_key: impl Into<String>,
        model: impl Into<String>,
    ) -> Self {
        Self {
            client: Client::new(),
            endpoint: endpoint.into(),
            api_key: api_key.into(),
            model: model.into(),
        }
    }

    pub async fn transcribe(&self, samples: &[i16]) -> Result<String, OpenAiError> {
        if samples.is_empty() {
            return Ok(String::new());
        }
        let boundary = format!(
            "sezish-{:x}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_nanos())
        );
        let body = multipart(
            &sez_core::wav::encode_pcm16_mono_16k(samples),
            &self.model,
            &boundary,
        );
        let response = self
            .client
            .post(&self.endpoint)
            .bearer_auth(&self.api_key)
            .header(
                "content-type",
                format!("multipart/form-data; boundary={boundary}"),
            )
            .body(body)
            .timeout(crate::timeout_for_sample_count(samples.len()))
            .send()
            .await?;
        let status = response.status();
        let bytes = response.bytes().await?;
        if !status.is_success() {
            return Err(OpenAiError::BadResponse {
                code: status.as_u16(),
                message: message_in(&bytes),
            });
        }
        #[derive(Deserialize)]
        struct Reply {
            text: String,
        }
        Ok(serde_json::from_slice::<Reply>(&bytes)?
            .text
            .trim()
            .to_owned())
    }
}

fn multipart(wav: &[u8], model: &str, boundary: &str) -> Vec<u8> {
    let mut body = Vec::with_capacity(wav.len() + 512);
    for (name, value) in [("model", model), ("response_format", "json")] {
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            )
            .as_bytes(),
        );
    }
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"take.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

/// `{"error":{"message":…}}` when OpenAI explains itself, else the body's start.
fn message_in(body: &[u8]) -> String {
    #[derive(Deserialize)]
    struct Inner {
        message: String,
    }
    #[derive(Deserialize)]
    struct Failure {
        error: Inner,
    }
    serde_json::from_slice::<Failure>(body).map_or_else(
        |_| String::from_utf8_lossy(&body[..body.len().min(200)]).into_owned(),
        |failure| failure.error.message,
    )
}

#[async_trait::async_trait]
impl Transcriber for OpenAiTranscriber {
    /// Nothing to pay up front: one request per finished take.
    fn warmup(&self) {}

    async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError> {
        Ok(OpenAiTranscriber::transcribe(self, samples).await?)
    }
}

#[cfg(test)]
mod tests {
    use super::{OpenAiError, OpenAiTranscriber, ENDPOINT};
    use httpmock::prelude::*;
    use sez_core::Transcriber;

    fn take() -> Vec<i16> {
        (0..8_000)
            .map(|i| (6_000.0 * (i as f32 * 220.0 * std::f32::consts::TAU / 16_000.0).sin()) as i16)
            .collect()
    }

    #[test]
    fn the_endpoint_is_openais() {
        assert_eq!(ENDPOINT, "https://api.openai.com/v1/audio/transcriptions");
    }

    #[tokio::test]
    async fn posts_the_take_as_a_wav_file_with_the_model_and_key() {
        let server = MockServer::start_async().await;
        let post = server
            .mock_async(|when, then| {
                when.method(POST)
                    .path("/v1/audio/transcriptions")
                    .header("authorization", "Bearer sk-test")
                    .header_matches("content-type", "^multipart/form-data; boundary=.+")
                    .body_includes("name=\"model\"\r\n\r\ngpt-transcribe\r\n")
                    .body_includes("name=\"response_format\"\r\n\r\njson\r\n")
                    .body_includes("filename=\"take.wav\"\r\nContent-Type: audio/wav")
                    .is_true(|request| request.body_ref().len() > 16_000);
                then.status(200).body(r#"{"text":"Привет, как дела?"}"#);
            })
            .await;
        let transcriber = OpenAiTranscriber::with_endpoint(
            server.url("/v1/audio/transcriptions"),
            "sk-test",
            "gpt-transcribe",
        );

        let text = transcriber.transcribe(&take()).await.unwrap();

        assert_eq!(text, "Привет, как дела?");
        post.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn the_mini_model_is_sent_by_name() {
        let server = MockServer::start_async().await;
        let post = server
            .mock_async(|when, then| {
                when.body_includes("gpt-4o-mini-transcribe");
                then.status(200).body(r#"{"text":"ok"}"#);
            })
            .await;
        OpenAiTranscriber::with_endpoint(server.url("/"), "k", "gpt-4o-mini-transcribe")
            .transcribe(&take())
            .await
            .unwrap();
        post.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn an_error_carries_openais_own_message() {
        let server = MockServer::start_async().await;
        server
            .mock_async(|_, then| {
                then.status(401)
                    .body(r#"{"error":{"message":"Incorrect API key provided."}}"#);
            })
            .await;
        let error = OpenAiTranscriber::with_endpoint(server.url("/"), "bad", "gpt-transcribe")
            .transcribe(&take())
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            OpenAiError::BadResponse { code: 401, ref message } if message == "Incorrect API key provided."
        ));
        assert_eq!(
            error.to_string(),
            "OpenAI ответил 401: Incorrect API key provided."
        );
    }

    #[tokio::test]
    async fn the_text_is_trimmed_and_silence_never_calls_out() {
        let server = MockServer::start_async().await;
        let post = server
            .mock_async(|_, then| {
                then.status(200).body("{\"text\":\"  да \\n\"}");
            })
            .await;
        let transcriber = OpenAiTranscriber::with_endpoint(server.url("/"), "k", "gpt-transcribe");
        assert_eq!(transcriber.transcribe(&take()).await.unwrap(), "да");
        assert_eq!(transcriber.transcribe(&[]).await.unwrap(), "");
        post.assert_calls_async(1).await;
    }

    #[tokio::test]
    async fn it_serves_as_the_dictation_seam() {
        let server = MockServer::start_async().await;
        server
            .mock_async(|_, then| {
                then.status(200).body(r#"{"text":"salom"}"#);
            })
            .await;
        let transcriber = OpenAiTranscriber::with_endpoint(server.url("/"), "k", "gpt-transcribe");
        transcriber.warmup();
        assert_eq!(
            Transcriber::transcribe(&transcriber, &take())
                .await
                .unwrap(),
            "salom"
        );
    }
}
