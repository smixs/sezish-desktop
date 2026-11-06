//! Dictation over OpenAI's `/v1/audio/transcriptions` on the user's own key
//! (macOS `OpenAITranscriber.swift`). The finished take goes up once as a
//! 16 kHz 16-bit WAV; a minute of speech is under 2 MB of the 25 allowed.

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
        assert_eq!(error.to_string(), "OpenAI ответил 401: Incorrect API key provided.");
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
        assert_eq!(Transcriber::transcribe(&transcriber, &take()).await.unwrap(), "salom");
    }
}
