use serde::{Deserialize, Serialize};

const API_URL: &str = "https://api.anthropic.com/v1/messages";
const MODEL: &str = "claude-haiku-4-5-20251001";

#[derive(Serialize)]
struct Message {
    role: &'static str,
    content: String,
}

#[derive(Serialize)]
struct ApiRequest {
    model: &'static str,
    max_tokens: u32,
    system: String,
    messages: Vec<Message>,
}

#[derive(Deserialize)]
struct ContentBlock {
    text: Option<String>,
}

#[derive(Deserialize)]
struct ApiResponse {
    content: Vec<ContentBlock>,
}

pub async fn refine_text(api_key: &str, raw_text: &str, style_prompt: &str) -> Result<String, String> {
    let system = format!(
        "You are a dictation assistant. The user spoke into a microphone and the speech was transcribed. \
        Clean up the transcription: fix grammar, remove filler words (um, uh, like), \
        remove false starts and repetitions, and make it read naturally.\n\n\
        Style instructions: {}\n\n\
        Rules:\n\
        - Output ONLY the cleaned text, nothing else\n\
        - Do not add explanations, prefixes, or quotes\n\
        - Preserve the original meaning exactly\n\
        - Keep the same language as the input\n\
        - If the input is already clean, return it as-is",
        style_prompt
    );

    let request = ApiRequest {
        model: MODEL,
        max_tokens: 4096,
        system,
        messages: vec![Message {
            role: "user",
            content: raw_text.to_string(),
        }],
    };

    let client = reqwest::Client::new();
    let response = client
        .post(API_URL)
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&request)
        .send()
        .await
        .map_err(|e| format!("API request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("API error {}: {}", status, body));
    }

    let api_response: ApiResponse = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse response: {}", e))?;

    api_response
        .content
        .first()
        .and_then(|b| b.text.clone())
        .ok_or_else(|| "Empty response from API".to_string())
}
