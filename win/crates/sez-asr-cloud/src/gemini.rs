//! Dictation over Gemini's unary `generateContent` on the user's own key (macOS
//! `GeminiBatchTranscriber.swift`). The finished take goes up once as base64 WAV.

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
        assert_eq!(GeminiMode::from_name("VERBATIM"), Some(GeminiMode::Verbatim));
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

        assert_eq!(transcriber.transcribe(&take()).await.unwrap(), "Привет, как дела?");
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
            transcript(blocked.to_string().as_bytes()).unwrap_err().to_string(),
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
        assert_eq!(transcript(joined.to_string().as_bytes()).unwrap(), "раз два");
    }

    #[tokio::test]
    async fn an_http_error_carries_the_body_start() {
        let server = MockServer::start_async().await;
        server
            .mock_async(|_, then| {
                then.status(400).body("API key not valid. Please pass a valid API key.");
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

        assert_eq!(error.to_string(), "Запись слишком длинная для Gemini: 600 с.");
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
            Transcriber::transcribe(&transcriber, &take()).await.unwrap(),
            "salom"
        );
        assert_eq!(transcriber.transcribe(&[]).await.unwrap(), "");
        post.assert_calls_async(1).await;
    }
}
