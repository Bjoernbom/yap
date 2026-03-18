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
        "You clean up speech-to-text transcriptions. The text was spoken by a human and transcribed by Whisper.\n\n\
        What to fix:\n\
        - Remove filler words: um, uh, eh, like, you know, typ, liksom, alltså (when used as filler)\n\
        - Remove repeated words or false starts: \"I I want\" → \"I want\"\n\
        - Fix obvious punctuation: add periods, commas, question marks where clearly needed\n\
        - Fix capitalization at sentence starts\n\n\
        What NOT to do:\n\
        - Do NOT change any real words the person said\n\
        - Do NOT rephrase, restructure, or rewrite sentences\n\
        - Do NOT add words that weren't spoken\n\
        - Do NOT correct grammar unless it's clearly a transcription error (not how they talk)\n\
        - Do NOT translate or change language\n\
        - Do NOT change technical terms, names, or jargon\n\n\
        {}\n\n\
        Output ONLY the cleaned text. No explanations, no quotes, no prefixes.",
        if style_prompt.is_empty() { "" } else { style_prompt }
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
