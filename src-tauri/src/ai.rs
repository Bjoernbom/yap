use serde::{Deserialize, Serialize};

use crate::transcribe::TranscriptSegment;

#[derive(Debug, Serialize, Deserialize)]
pub struct StructuredOutput {
    pub title: String,
    pub summary: Option<String>,
    pub cleaned_transcript: String,
    pub action_items: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ActionItem {
    pub text: String,
    pub assignee: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SpeakerInfo {
    pub label: String,
    pub suggested_name: Option<String>,
    pub role: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MeetingStructuredOutput {
    pub title: String,
    pub summary: Option<String>,
    pub cleaned_transcript: String,
    pub action_items: Vec<ActionItem>,
    pub speakers: Vec<SpeakerInfo>,
    pub key_decisions: Vec<String>,
}

pub async fn structure_transcript(
    api_key: &str,
    transcript: &str,
) -> Result<StructuredOutput, String> {
    let client = reqwest::Client::new();

    let body = serde_json::json!({
        "model": "claude-sonnet-4-20250514",
        "max_tokens": 4096,
        "system": r#"You process voice transcripts. Always respond with valid JSON containing exactly these fields:

- "title": A short, descriptive title for the content.
- "cleaned_transcript": A cleaned-up, well-structured version of the raw transcript in Markdown. Fix grammar, remove filler words, organize into paragraphs. Preserve the original meaning and all information. Use headings, lists, and emphasis where appropriate to improve readability.
- "summary": A brief 2-3 sentence summary. Set to null if the transcript is too short or simple to warrant a summary.
- "action_items": An array of action items extracted from the transcript. Empty array if none.

Write in the same language as the transcript. Respond ONLY with JSON, no other text."#,
        "messages": [
            {
                "role": "user",
                "content": format!("Process this voice transcript:\n\n{}", transcript)
            },
            {
                "role": "assistant",
                "content": "{"
            }
        ]
    });

    let response = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("API request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(format!("API error ({}): {}", status, text));
    }

    let api_response: serde_json::Value = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse API response: {}", e))?;

    let content_text = api_response["content"][0]["text"]
        .as_str()
        .ok_or("No text in API response")?;

    let json_text = format!("{{{}", content_text);
    let json_text = strip_code_fences(&json_text);

    let output: StructuredOutput = serde_json::from_str(&json_text)
        .map_err(|e| format!("Failed to parse structured output: {}. Raw: {}", e, &json_text[..json_text.len().min(200)]))?;

    Ok(output)
}

pub async fn structure_meeting(
    api_key: &str,
    segments: &[TranscriptSegment],
) -> Result<MeetingStructuredOutput, String> {
    let client = reqwest::Client::new();

    // Build the transcript text with speaker labels
    let transcript_text: String = segments
        .iter()
        .map(|s| {
            let label = s.speaker_label.as_deref().unwrap_or("Unknown");
            let time = format_ms(s.start_ms);
            format!("[{} @ {}] {}", label, time, s.text)
        })
        .collect::<Vec<_>>()
        .join("\n");

    let body = serde_json::json!({
        "model": "claude-sonnet-4-20250514",
        "max_tokens": 8192,
        "system": r#"You process meeting transcripts with speaker labels. The transcript has format: [Speaker @ timestamp] text

Always respond with valid JSON containing exactly these fields:

- "title": A short, descriptive title for the meeting.
- "summary": A 2-4 sentence summary of the meeting's purpose and outcomes.
- "cleaned_transcript": A cleaned-up markdown transcript with format:
  **[Speaker Name]** (timestamp)
  > Text

  Fix grammar, remove filler words. Group consecutive segments from the same speaker.
- "action_items": Array of objects with "text" (action description) and "assignee" (speaker label or null).
- "speakers": Array of objects with "label" (original label like "Speaker 1"), "suggested_name" (real name if mentioned in transcript, or null), and "role" (inferred role like "projektledare" if apparent, or null).
- "key_decisions": Array of key decisions made during the meeting. Empty array if none.

Identify speakers by context clues (names mentioned, introductions, references).
Write in the same language as the transcript. Respond ONLY with JSON, no other text."#,
        "messages": [
            {
                "role": "user",
                "content": format!("Process this meeting transcript:\n\n{}", transcript_text)
            },
            {
                "role": "assistant",
                "content": "{"
            }
        ]
    });

    let response = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("API request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(format!("API error ({}): {}", status, text));
    }

    let api_response: serde_json::Value = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse API response: {}", e))?;

    let content_text = api_response["content"][0]["text"]
        .as_str()
        .ok_or("No text in API response")?;

    let json_text = format!("{{{}", content_text);
    let json_text = strip_code_fences(&json_text);

    let output: MeetingStructuredOutput = serde_json::from_str(&json_text)
        .map_err(|e| format!("Failed to parse meeting output: {}. Raw: {}", e, &json_text[..json_text.len().min(200)]))?;

    Ok(output)
}

fn strip_code_fences(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.starts_with("```") {
        let without_start = trimmed
            .strip_prefix("```json")
            .or_else(|| trimmed.strip_prefix("```"))
            .unwrap_or(trimmed);
        without_start
            .strip_suffix("```")
            .unwrap_or(without_start)
            .trim()
            .to_string()
    } else {
        trimmed.to_string()
    }
}

fn format_ms(ms: i64) -> String {
    let total_secs = ms / 1000;
    let mins = total_secs / 60;
    let secs = total_secs % 60;
    format!("{}:{:02}", mins, secs)
}
