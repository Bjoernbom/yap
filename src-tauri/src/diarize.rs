use pyannote_rs::{EmbeddingExtractor, EmbeddingManager};
use serde::{Deserialize, Serialize};

const SIMILARITY_THRESHOLD: f32 = 0.5;
const MAX_SPEAKERS: usize = 10;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiarizedSegment {
    pub start_s: f64,
    pub end_s: f64,
    pub speaker_label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiarizeResult {
    pub segments: Vec<DiarizedSegment>,
    pub num_speakers: usize,
}

pub fn diarize_audio(
    audio_path: &str,
    segmentation_model_path: &str,
    embedding_model_path: &str,
) -> Result<DiarizeResult, String> {
    let (samples, sample_rate) =
        pyannote_rs::read_wav(audio_path).map_err(|e| format!("Failed to read WAV: {}", e))?;

    if samples.is_empty() {
        return Ok(DiarizeResult {
            segments: vec![],
            num_speakers: 0,
        });
    }

    let segments = pyannote_rs::get_segments(&samples, sample_rate, segmentation_model_path)
        .map_err(|e| format!("Segmentation failed: {}", e))?;

    let mut extractor = EmbeddingExtractor::new(embedding_model_path)
        .map_err(|e| format!("Failed to load embedding model: {}", e))?;

    let mut manager = EmbeddingManager::new(MAX_SPEAKERS);
    let mut result_segments: Vec<DiarizedSegment> = Vec::new();

    for segment_result in segments {
        let segment = match segment_result {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Segment processing error: {:?}", e);
                continue;
            }
        };

        let speaker_id = match extractor.compute(&segment.samples) {
            Ok(embedding) => {
                let embedding_vec: Vec<f32> = embedding.collect();
                if manager.get_all_speakers().len() >= MAX_SPEAKERS {
                    manager
                        .get_best_speaker_match(embedding_vec)
                        .unwrap_or(0)
                } else {
                    manager
                        .search_speaker(embedding_vec, SIMILARITY_THRESHOLD)
                        .unwrap_or(0)
                }
            }
            Err(_) => 0,
        };

        result_segments.push(DiarizedSegment {
            start_s: segment.start,
            end_s: segment.end,
            speaker_label: format!("Speaker {}", speaker_id + 1),
        });
    }

    let num_speakers = manager.get_all_speakers().len();

    Ok(DiarizeResult {
        segments: result_segments,
        num_speakers,
    })
}

/// Model file names for pyannote
pub const SEGMENTATION_MODEL: &str = "segmentation-3.0.onnx";
pub const EMBEDDING_MODEL: &str = "wespeaker_en_voxceleb_CAM++.onnx";

/// URLs for downloading pyannote models
pub const SEGMENTATION_MODEL_URL: &str =
    "https://github.com/thewh1teagle/pyannote-rs/releases/download/v0.1.0/segmentation-3.0.onnx";
pub const EMBEDDING_MODEL_URL: &str =
    "https://github.com/thewh1teagle/pyannote-rs/releases/download/v0.1.0/wespeaker_en_voxceleb_CAM++.onnx";
