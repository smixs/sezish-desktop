//! Dictation over Gemini's unary `generateContent` on the user's own key (macOS
//! `GeminiBatchTranscriber.swift`). The finished take goes up once as base64 WAV.

use base64::Engine as _;
use reqwest::Client;
use serde::Deserialize;
use sez_core::{SezError, Transcriber};
use thiserror::Error;

/// Pinned, not `-latest`: an alias moving under a shipped app changes recognition
/// behaviour without a release.
pub const MODEL: &str = "gemini-2.5-flash";
pub const ENDPOINT: &str =
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";
/// The request as a whole may not exceed 20 MB, prompt and JSON included.
const MAX_PAYLOAD_BYTES: usize = 18 * 1_024 * 1_024;
const ERROR_BODY_LIMIT: usize = 200;

/// How the transcript is cleaned up (Mac `GeminiTranscriptionMode`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum GeminiMode {
    /// Punctuation, no filler words, stutters or false starts.
    #[default]
    Smart,
    /// What was said, word for word.
    Verbatim,
}

impl GeminiMode {
    pub const ALL: [Self; 2] = [Self::Smart, Self::Verbatim];

    pub fn name(self) -> &'static str {
        match self {
            Self::Smart => "SMART",
            Self::Verbatim => "VERBATIM",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|mode| mode.name() == name)
    }
}

#[derive(Debug, Error)]
pub enum GeminiError {
    #[error("Gemini ответил {code}: {body}")]
    BadResponse { code: u16, body: String },
    #[error("Gemini не отдал текст ({0}).")]
    Blocked(String),
    #[error("Gemini вернул пустой текст.")]
    EmptyTranscript,
    #[error("Запись слишком длинная для Gemini: {0} с.")]
    AudioTooLong(usize),
    #[error("Gemini request failed: {0}")]
    Request(#[from] reqwest::Error),
    #[error("Gemini response was invalid JSON: {0}")]
    Decode(#[from] serde_json::Error),
}

impl From<GeminiError> for SezError {
    fn from(error: GeminiError) -> Self {
        match error {
            GeminiError::Request(source) if source.is_timeout() => Self::Timeout,
            other => Self::Other(other.to_string()),
        }
    }
}

/// SMART and VERBATIM are Live-side server settings with no unary equivalent, so the
/// difference is spelled out to the model instead.
pub fn prompt(mode: GeminiMode) -> String {
    let common = "Keep the speaker's own language. \
                  Return only the transcript text: no commentary, no quotes, no markdown.";
    match mode {
        GeminiMode::Smart => format!(
            "Transcribe the speech in this recording. Add punctuation and capitalization, \
             drop filler words, stutters and false starts. {common}"
        ),
        GeminiMode::Verbatim => format!(
            "Transcribe the speech in this recording word for word. \
             Keep filler words, stutters and repetitions exactly as spoken. {common}"
        ),
    }
}

/// The text of the first candidate. An answer without one carries its reason (safety,
/// recitation, token budget) and is an error: an empty string would be stored as a
/// successful empty take.
pub fn transcript(body: &[u8]) -> Result<String, GeminiError> {
    #[derive(Deserialize)]
    struct Part {
        text: Option<String>,
    }
    #[derive(Deserialize)]
    struct Content {
        parts: Option<Vec<Part>>,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Candidate {
        content: Option<Content>,
        finish_reason: Option<String>,
    }
    #[derive(Deserialize)]
    struct Reply {
        candidates: Option<Vec<Candidate>>,
    }

    let reply: Reply = serde_json::from_slice(body)?;
    let Some(candidate) = reply.candidates.and_then(|all| all.into_iter().next()) else {
        return Err(GeminiError::Blocked("no candidates".to_owned()));
    };
    let text = candidate
        .content
        .and_then(|content| content.parts)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|part| part.text)
        .collect::<String>();
    let text = text.trim();
    if !text.is_empty() {
        return Ok(text.to_owned());
    }
    match candidate.finish_reason {
        Some(reason) if reason != "STOP" => Err(GeminiError::Blocked(reason)),
        _ => Err(GeminiError::EmptyTranscript),
    }
}

#[derive(Clone)]
pub struct GeminiTranscriber {
    client: Client,
    endpoint: String,
    api_key: String,
    mode: GeminiMode,
}

impl GeminiTranscriber {
    pub fn new(api_key: impl Into<String>, mode: GeminiMode) -> Self {
        Self::with_endpoint(ENDPOINT, api_key, mode)
    }

    pub fn with_endpoint(
        endpoint: impl Into<String>,
        api_key: impl Into<String>,
        mode: GeminiMode,
    ) -> Self {
        Self {
            client: Client::new(),
            endpoint: endpoint.into(),
            api_key: api_key.into(),
            mode,
        }
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    pub async fn transcribe(&self, samples: &[i16]) -> Result<String, GeminiError> {
        if samples.is_empty() {
            return Ok(String::new());
        }
        let wav = sez_core::wav::encode_pcm16_mono_16k(samples);
        if wav.len().div_ceil(3) * 4 > MAX_PAYLOAD_BYTES {
            return Err(GeminiError::AudioTooLong(
                samples.len() / sez_core::wav::SAMPLE_RATE as usize,
            ));
        }
        let audio = base64::engine::general_purpose::STANDARD.encode(wav);
        let body = serde_json::json!({
            "contents": [{ "parts": [
                { "text": prompt(self.mode) },
                { "inline_data": { "mime_type": "audio/wav", "data": audio } },
            ] }],
            // Nothing to reason about in a transcript; thinking is latency for nothing.
            "generationConfig": { "temperature": 0, "thinkingConfig": { "thinkingBudget": 0 } },
        });
        let response = self
            .client
            .post(&self.endpoint)
            // In a header, not the URL: error text and logs quote URLs.
            .header("x-goog-api-key", &self.api_key)
            .json(&body)
            .timeout(crate::timeout_for_sample_count(samples.len()))
            .send()
            .await?;
        let status = response.status();
        let bytes = response.bytes().await?;
        if !status.is_success() {
            return Err(GeminiError::BadResponse {
                code: status.as_u16(),
                body: String::from_utf8_lossy(&bytes[..bytes.len().min(ERROR_BODY_LIMIT)])
                    .into_owned(),
            });
        }
        transcript(&bytes)
    }
}

#[async_trait::async_trait]
impl Transcriber for GeminiTranscriber {
    /// Nothing to pay up front: one request per finished take.
    fn warmup(&self) {}

    async fn transcribe(&self, samples: &[i16]) -> Result<String, SezError> {
        Ok(GeminiTranscriber::transcribe(self, samples).await?)
    }
}

#[cfg(test)]
mod tests {
    use super::{prompt, transcript, GeminiError, GeminiMode, GeminiTranscriber, MODEL};
    use httpmock::prelude::*;
    use sez_core::Transcriber;

    fn take() -> Vec<i16> {
        (0..8_000)
            .map(|i| (6_000.0 * (i as f32 * 220.0 * std::f32::consts::TAU / 16_000.0).sin()) as i16)
            .collect()
    }

    fn reply(text: &str) -> String {
        serde_json::json!({
            "candidates": [{ "content": { "parts": [{ "text": text }] }, "finishReason": "STOP" }]
        })
        .to_string()
    }

    /// Pinned, not `-latest`: an alias moving under a shipped app changes recognition
    /// without a release (Mac, verified 2026-08-27).
    #[test]
    fn the_model_is_pinned() {
        assert_eq!(MODEL, "gemini-2.5-flash");
    }

    #[test]
    fn modes_carry_the_mac_names_and_prompts() {
        assert_eq!(GeminiMode::Smart.name(), "SMART");
        assert_eq!(GeminiMode::Verbatim.name(), "VERBATIM");
        assert_eq!(
            GeminiMode::from_name("VERBATIM"),
            Some(GeminiMode::Verbatim)
        );
        assert_eq!(GeminiMode::from_name("smart"), None);
        assert_eq!(GeminiMode::default(), GeminiMode::Smart);

        let common = "Keep the speaker's own language. \
                      Return only the transcript text: no commentary, no quotes, no markdown.";
        assert_eq!(
            prompt(GeminiMode::Smart),
            format!(
                "Transcribe the speech in this recording. Add punctuation and capitalization, \
                 drop filler words, stutters and false starts. {common}"
            )
        );
        assert_eq!(
            prompt(GeminiMode::Verbatim),
            format!(
                "Transcribe the speech in this recording word for word. \
                 Keep filler words, stutters and repetitions exactly as spoken. {common}"
            )
        );
    }

    #[tokio::test]
    async fn posts_the_take_with_the_key_in_a_header_and_no_thinking() {
        let server = MockServer::start_async().await;
        let post = server
            .mock_async(|when, then| {
                when.method(POST)
                    .path("/v1beta/models/gemini-2.5-flash:generateContent")
                    .header("x-goog-api-key", "g-test")
                    .header("content-type", "application/json")
                    .is_true(|request| {
                        let body: serde_json::Value =
                            serde_json::from_slice(request.body_ref()).unwrap();
                        let parts = &body["contents"][0]["parts"];
                        parts[0]["text"].as_str().unwrap().starts_with("Transcribe")
                            && parts[1]["inline_data"]["mime_type"] == "audio/wav"
                            && parts[1]["inline_data"]["data"].as_str().unwrap().len() > 16_000
                            && body["generationConfig"]["temperature"] == 0
                            && body["generationConfig"]["thinkingConfig"]["thinkingBudget"] == 0
                    });
                then.status(200).body(reply(" Привет, как дела? \n"));
            })
            .await;
        let transcriber = GeminiTranscriber::with_endpoint(
            server.url("/v1beta/models/gemini-2.5-flash:generateContent"),
            "g-test",
            GeminiMode::Smart,
        );

        assert_eq!(
            transcriber.transcribe(&take()).await.unwrap(),
            "Привет, как дела?"
        );
        post.assert_calls_async(1).await;
        // The key never travels in the URL: error text and logs quote URLs.
        assert!(!transcriber.endpoint().contains("g-test"));
    }

    #[test]
    fn an_answer_without_text_is_an_error_with_its_reason() {
        let blocked = serde_json::json!({
            "candidates": [{ "content": { "parts": [] }, "finishReason": "SAFETY" }]
        });
        assert_eq!(
            transcript(blocked.to_string().as_bytes())
                .unwrap_err()
                .to_string(),
            "Gemini не отдал текст (SAFETY)."
        );
        let empty = reply("  ");
        assert_eq!(
            transcript(empty.as_bytes()).unwrap_err().to_string(),
            "Gemini вернул пустой текст."
        );
        assert_eq!(
            transcript(br#"{"candidates":[]}"#).unwrap_err().to_string(),
            "Gemini не отдал текст (no candidates)."
        );
        let joined = serde_json::json!({
            "candidates": [{ "content": { "parts": [{ "text": "раз " }, { "text": "два" }] } }]
        });
        assert_eq!(
            transcript(joined.to_string().as_bytes()).unwrap(),
            "раз два"
        );
    }

    #[tokio::test]
    async fn an_http_error_carries_the_body_start() {
        let server = MockServer::start_async().await;
        server
            .mock_async(|_, then| {
                then.status(400)
                    .body("API key not valid. Please pass a valid API key.");
            })
            .await;
        let error = GeminiTranscriber::with_endpoint(server.url("/"), "bad", GeminiMode::Smart)
            .transcribe(&take())
            .await
            .unwrap_err();
        assert!(matches!(error, GeminiError::BadResponse { code: 400, .. }));
        assert_eq!(
            error.to_string(),
            "Gemini ответил 400: API key not valid. Please pass a valid API key."
        );
    }

    /// The whole request may not exceed 20 MB; past the tripwire nothing goes out.
    #[tokio::test]
    async fn a_take_too_long_for_one_request_never_calls_out() {
        let server = MockServer::start_async().await;
        let post = server
            .mock_async(|_, then| {
                then.status(200).body(reply("x"));
            })
            .await;
        let transcriber = GeminiTranscriber::with_endpoint(server.url("/"), "k", GeminiMode::Smart);
        let ten_minutes = vec![1_i16; 16_000 * 600];

        let error = transcriber.transcribe(&ten_minutes).await.unwrap_err();

        assert_eq!(
            error.to_string(),
            "Запись слишком длинная для Gemini: 600 с."
        );
        post.assert_calls_async(0).await;
    }

    #[tokio::test]
    async fn verbatim_sends_its_own_prompt_and_silence_never_calls_out() {
        let server = MockServer::start_async().await;
        let post = server
            .mock_async(|when, then| {
                when.body_includes("word for word");
                then.status(200).body(reply("salom"));
            })
            .await;
        let transcriber =
            GeminiTranscriber::with_endpoint(server.url("/"), "k", GeminiMode::Verbatim);
        transcriber.warmup();
        assert_eq!(
            Transcriber::transcribe(&transcriber, &take())
                .await
                .unwrap(),
            "salom"
        );
        assert_eq!(transcriber.transcribe(&[]).await.unwrap(), "");
        post.assert_calls_async(1).await;
    }
}
