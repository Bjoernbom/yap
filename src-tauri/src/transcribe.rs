use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub struct WhisperState {
    ctx: Option<WhisperContext>,
    model_path: Option<String>,
}

impl WhisperState {
    pub fn new() -> Self {
        Self {
            ctx: None,
            model_path: None,
        }
    }

    pub fn is_loaded(&self) -> bool {
        self.ctx.is_some()
    }

    pub fn ensure_loaded(&mut self, model_path: &str) -> Result<(), String> {
        // Reload if model path changed
        if let Some(ref current) = self.model_path {
            if current == model_path && self.ctx.is_some() {
                return Ok(());
            }
        }

        let ctx = WhisperContext::new_with_params(
            model_path,
            WhisperContextParameters::default(),
        )
        .map_err(|e| format!("Failed to load whisper model: {}", e))?;

        self.ctx = Some(ctx);
        self.model_path = Some(model_path.to_string());
        Ok(())
    }

    pub fn transcribe_samples(
        &self,
        samples: &[f32],
        language: Option<&str>,
        initial_prompt: Option<&str>,
    ) -> Result<String, String> {
        let ctx = self.ctx.as_ref().ok_or("Whisper model not loaded")?;
        let mut state = ctx
            .create_state()
            .map_err(|e| format!("Failed to create state: {}", e))?;

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(language);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_single_segment(true);

        if let Some(prompt) = initial_prompt {
            params.set_initial_prompt(prompt);
        }

        state
            .full(params, samples)
            .map_err(|e| format!("Transcription failed: {}", e))?;

        let num_segments = state
            .full_n_segments()
            .map_err(|e| format!("Failed to get segments: {}", e))?;

        let mut transcript = String::new();
        for i in 0..num_segments {
            let text = state
                .full_get_segment_text(i)
                .map_err(|e| format!("Failed to get segment {}: {}", i, e))?;
            transcript.push_str(text.trim());
            if i < num_segments - 1 {
                transcript.push(' ');
            }
        }

        Ok(transcript)
    }
}
