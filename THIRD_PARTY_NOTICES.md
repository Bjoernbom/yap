# Third-party notices

yap is MIT-licensed (see [LICENSE](LICENSE)). It builds on the work below,
each under its own license. Thank you to everyone who made these.

## Libraries (compiled into yap)

| Project | License | Copyright |
| --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 | FluidInference. Includes components under their own licenses, listed in its [ThirdPartyLicenses](https://github.com/FluidInference/FluidAudio/tree/main/ThirdPartyLicenses) folder |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Gwendal Roué |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT-style | Andy Matuschak and the Sparkle Project contributors |
| [Pixelify Sans](https://github.com/google/fonts/tree/main/ofl/pixelifysans) | SIL Open Font License 1.1 | The Pixelify Sans Project Authors; full license text included with yap |

## Models (downloaded on first run, not bundled with yap)

| Model | Used for | License | Credit |
| --- | --- | --- | --- |
| [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | Speech-to-text | CC BY 4.0 | NVIDIA |
| [parakeet-ultra](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | Speech-to-text (default weights) | CC BY 4.0 | Fine-tune of Parakeet by moondream; Core ML conversion by FluidInference |
| [Silero VAD](https://huggingface.co/FluidInference/silero-vad-coreml) | Detecting pauses in speech | MIT | Silero Team; Core ML conversion by FluidInference |
| [speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) | Telling speakers apart in notes | CC BY 4.0 (scoped, see its NOTICE) | Based on pyannote speaker-diarization-community-1; Core ML conversion by FluidInference |

Apple's Foundation Models framework (optional polish and summaries) is part of
macOS and covered by Apple's own terms.
