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

pub async fn refine_text(api_key: &str, raw_text: &str, style_prompt: &str, language: &str) -> Result<String, String> {
    let lang_hint = match language {
        "sv" => "The user is speaking Swedish. Output MUST be in Swedish.",
        "en" => "The user is speaking English. Output MUST be in English.",
        "de" => "The user is speaking German. Output MUST be in German.",
        "fr" => "The user is speaking French. Output MUST be in French.",
        "es" => "The user is speaking Spanish. Output MUST be in Spanish.",
        "no" => "The user is speaking Norwegian. Output MUST be in Norwegian.",
        "da" => "The user is speaking Danish. Output MUST be in Danish.",
        "ja" => "The user is speaking Japanese. Output MUST be in Japanese.",
        _ => "Keep the same language as the input.",
    };
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
        - Do NOT translate or change language — if the input is Swedish, output Swedish. If English, output English. NEVER switch languages\n\
        - Do NOT change technical terms, names, or jargon\n\n\
        CRITICAL: {}\n\n\
        {}\n\n\
        Output ONLY the cleaned text. No explanations, no quotes, no prefixes.",
        lang_hint,
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
