# Spike M0-ASR: Parakeet TDT v3 via FluidAudio

**Question.** Is FluidAudio's Parakeet TDT v3 (Core ML, Neural Engine) good and
fast enough to be yap's only speech engine for Swedish and English, and how do
we "transcribe while you talk" so key-up → text stays constant for long
dictations?

**Verdict: go, with caveats.** Accuracy is inside the plan's budget
(sv 16.7 %, en 5.4 % WER vs the ≤ 40 % ceiling), a warm model transcribes a
≤ 14 s chunk in 50–170 ms, and VAD chunking keeps key-up → text at 35–55 ms
for a 2-minute dictation (the whole clip in one go takes 0.4–1.1 s).
Caveats: use the **Ultra** weights rather than plain v3 (−2.3 pp WER on
Swedish, same API and speed), budget ~0.5–0.6 GB of Neural Engine memory
that Activity Monitor doesn't show, and plan the custom dictionary as
post-processing, because FluidAudio's vocabulary boosting helps but also
introduces errors.

## Setup

| | |
|---|---|
| Machine | Apple M3 Pro, 18 GB RAM, macOS 26.6.2 (swap already under pressure during the runs) |
| Library | FluidAudio 0.17.4 (`AsrManager`, `AsrModels`, `VadManager`, `VocabularyBoostingSession`) |
| Models | `parakeet-tdt-0.6b-v3` (6-bit encoder, default `int8` variant), `parakeet-ultra` (int8 encoder), Silero VAD v6.2.1, `parakeet-ctc-110m` for vocabulary boosting |
| Build | `swift build -c release`, Swift 6.2.1 |
| Speech data | FLEURS test split, the first 30 unique sentences per language (`sv_se` 327 s, `en_us` 284 s). Read speech, not spontaneous dictation |
| Code-switching | 10 **synthetic** Swedish sentences with English tech terms, spoken by the macOS `Alva` voice |
| WER | Corpus-level (total edits / total reference words). "Normalized": lowercase, punctuation → space, collapse whitespace. "Raw": case and punctuation count |
| Latency | Wall time of `AsrManager.transcribe` on samples already in memory, after one warm-up call. Mic, cleanup and paste are not included |

Our 30-clip sample tracks FluidAudio's published full-set FLEURS numbers for v3
(sv 16.8 %, en 5.4 %), so the sample is representative.

## Results

### Model size and load

| | v3 | Ultra |
|---|---:|---:|
| Download (on disk) | 461 MB | 603 MB |
| Download time (this network) | 57 s | 76 s |
| First load after download, incl. ANE compile (cold) | 20.5 s | 16.9 s |
| Load from ANE cache (warm) | 0.37 s | 0.41 s |
| First transcription after load | 89–131 ms | 70–85 ms |
| Silero VAD | 1 MB, loads in < 0.1 s warm | |

A cold compile happens once per model path: copying the model folder to a new
path triggered it again (20.8 s), and it is cached after that.

### Accuracy and speed

| Set | Model | WER norm. | WER raw | Median / p95 / max latency | RTFx |
|---|---|---:|---:|---:|---:|
| FLEURS sv (30) | v3 | **16.7 %** | 22.8 % | 73 / 148 / 287 ms | 122 |
| FLEURS sv (30) | Ultra | **14.4 %** | 20.1 % | 68 / 138 / 280 ms | 133 |
| FLEURS en (30) | v3 | **5.4 %** | 12.9 % | 67 / 167 / 274 ms | 122 |
| FLEURS en (30) | Ultra | **5.4 %** | 12.1 % | 68 / 89 / 115 ms | 139 |
| Code-switch sv+en (10, synthetic) | v3 | 25.9 % | 28.4 % | 59 / 75 / 75 ms | 83 |
| Code-switch sv+en (10, synthetic) | Ultra | 22.2 % | 26.5 % | 54 / 57 / 57 ms | 78 |

- Clips up to 14.5 s (one 15 s encoder window) take at most 83–167 ms (mean
  64–71 ms). Clips over 15 s need two windows and take 115–287 ms.
- Latency is almost flat in clip length: the encoder always runs on a padded
  15 s window.
- Numbers are part of the WER. Parakeet writes digits ("19", "2335", "halv
  sju") where FLEURS spells words out. Without the clips that contain digits,
  sv WER is 13.3 % (v3) / 10.7 % (Ultra) and en is 3.8 % / 4.4 %.

### Memory

| | v3 | Ultra |
|---|---:|---:|
| Process footprint, idle with model loaded | 30–60 MB | 37–62 MB |
| Process footprint, peak during transcription | 76 MB (2-min clip: 96–103 MB) | 74 MB (2-min clip: 94–98 MB) |
| Resident, peak during cold load | 480 MB | 625 MB |
| **Neural Engine memory while loaded** (`ri_neural_footprint`) | **468 MB** | **607 MB** |
| After `AsrManager.cleanup()` and release | neural 0 MB, footprint 20–28 MB | same |

The ANE owns the weights on the process's behalf. `footprint(1)` lists them as
"Owned physical footprint (neural) (nofootprint)", 439 MB of 468 MB marked
*reclaimable*. They are not in `phys_footprint`, so Activity Monitor shows
yap at ~60 MB while ~0.5 GB is actually in use. Read
`proc_pid_rusage(RUSAGE_INFO_V6).ri_neural_footprint` to track it.

### Long dictation: after release vs while talking

Two ~2-minute Swedish clips, each made from FLEURS utterances in a row
(a: 11 utterances, 123 s, 188 words; b: 12 utterances, 121 s, 240 words).
(a) transcribes the whole clip after the audio ends (FluidAudio's own
long-form path with overlapping 15 s windows). (b) simulates live capture:
256 ms hops go through Silero VAD streaming (`processStreamingChunk`), a chunk
is cut and transcribed as soon as VAD reports speech end, with a hard cap at
14 s (force-cut at the quietest hop in the last 4 s), and at release only the
tail is left. "Final" is end of audio → joined text. WER is over both clips
(428 words). For a baseline, the same utterances transcribed one by one give
16.8 % (v3) / 15.7 % (Ultra).

| Strategy | v3 final | v3 WER | Ultra final | Ultra WER |
|---|---:|---:|---:|---:|
| (a) whole clip after release | 1116 / 670 ms | 24.5 % | 1042 / 425 ms | 18.0 % |
| (b) VAD, cut at every pause (min silence 0.5 s) | **38 / 51 ms** | **18.7 %** | **34 / 55 ms** | **15.4 %** |
| (b) VAD, min silence 0.3 s | 37 / 50 ms | 18.7 % | 34 / 54 ms | 15.4 % |
| (b) VAD, only cut once chunk ≥ 5 s | 36 / 48 ms | 21.0 % | 36 / 51 ms | 16.1 % |
| (b) same + carry decoder state across chunks | 36 / 49 ms | 20.3 % | 36 / 52 ms | 16.1 % |
| (b) blind fixed 10 s windows | 72 / 61 ms | 23.8 % | 71 / 66 ms | 19.2 % |

- While talking, each chunk (4.4–14.1 s) took 34–145 ms, far less than the
  audio it covers, so there's never a backlog. VAD cost ~95 ms of compute
  per 2 minutes of audio.
- Chunking at pauses doesn't hurt accuracy. It beats FluidAudio's own
  long-form pass (which smears across sentence boundaries: "Ludregering,
  gudmexning ochrimaal manus") and is close to perfect sentence segmentation.
  Blind fixed windows cut words in half and cost 4–5 pp.
- Carrying the TDT decoder's LSTM state into the next chunk made no
  consistent difference. Fresh state per chunk is simpler.
- The tails here were short (0.3 s / 4.7 s) because FLEURS clips end in
  silence. The worst case is a tail up to the 14 s cap, which costs one
  single-window call: ≤ 170 ms warm.

### Idle and wake-up

| Idle before the call | 0 s | 5 s | 30 s | 90 s |
|---|---:|---:|---:|---:|
| v3, 5.8 s clip | 61 ms | 110 ms | 170 ms | 257 ms |

The ANE powers down between calls. After a minute of idle the first
transcription costs 2–4× more. Pre-warming at key-down hides this.

### Language behaviour

- **No language hint is needed.** Swedish comes out Swedish and English
  English, with no hint and no detection step. Parakeet decides per token.
- The `language:` parameter only filters *scripts* (Latin vs Cyrillic).
  Passing `.swedish` gave identical hypotheses on all 30 sv clips. It is only
  useful to stop Cyrillic leaking into Latin-script languages.
- English phrases inside Swedish sentences are kept in English when they're
  clearly English ("Sanctuary of Our Lady of Fatima", "science fiction",
  "feature branch"). English words that take Swedish inflection get Swedish
  spelling: "PullRekvästen", "reaktkomponenten", "deploa tills taging",
  "kaschen", "rådmapen". This is on synthetic TTS with Swedish-accented
  English, so real speakers may do better or worse.

### Custom vocabulary

The Parakeet TDT decoder has **no native context biasing or keyword boosting**.
FluidAudio offers CTC-based *rescoring* after the fact. A second encoder
(`parakeet-ctc-110m`, 98 MB, English 1024-token vocabulary) scores the
vocabulary terms against the audio, and words in the transcript are replaced
when the term has stronger acoustic evidence.

```swift
let ctc = try await CtcModels.load(from: ctcDirectory, variant: .ctc110m)
let vocabulary = CustomVocabularyContext(terms: [
	CustomVocabularyTerm(text: "Kubernetes", aliases: ["kubenets"]),
])
let boosting = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctc)
let output = await boosting.rescore(
	text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
// output?.text, output?.replacements; or rescorer.ctcTokenEvaluateCandidates(...) to apply our own policy
```

`SlidingWindowAsrManager` and `UnifiedAsrManager` have the same thing as
`configureVocabularyBoosting(vocabulary:ctcModels:)`. Gotcha: the session reads
the CTC tokenizer from the library's default cache directory
(`~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`),
whatever directory the models were loaded from.

Result on the code-switch set with 12 terms (v3): WER **25.9 % → 20.4 %**,
~145 ms per 3–6 s clip, +3 MB footprint.

- Fixed: deploya, staging, branch, Kubernetes, reviewa.
- Broke: "Backen teamet" → "**Cachen** teamet" (false positive), and
  "backlagen." → "backlog" (dropped the Swedish suffix and the period).
- `detectedTerms` listed every term for every clip, so it can't be used as a
  signal that a term was spoken.

### Edge cases (probes)

| Input | Result |
|---|---|
| Missing file / random bytes | `AVAudioFile` error from `ExtAudioFileOpenURL`, exit 1 |
| 0.2 s of speech | throws `ASRError.invalidAudioData` (minimum is 0.3 s) |
| 0.4 s of speech (a word fragment) | `""`, confidence 0.10 |
| 3 s of digital silence | `""`, confidence 0.10, so no hallucinated text (unlike Whisper) |

### Binary size

FluidAudio's Swift 6.2 manifest turns on the `NemoTextProcessing` trait by
default (a prebuilt Rust library for inverse text normalization). The stripped
`asr-bench` binary is 14.3 MB with it and **6.2 MB with `traits: []`**. The plan
budgets < 15 MB for the whole app, so we must turn the trait off (we don't use
its ITN).

## Recommendations for `YapKit/Speech`

1. **Engine.** Use `ParakeetEngine` on `AsrModelVersion.ultra`. Keep the version
   in one place so v3 stays a one-line fallback. Depend on FluidAudio with
   `traits: []`.
2. **API shape.**
   ```swift
   public protocol SpeechEngine: Actor {
   	func prepare() async throws                 // download if needed, load, compile; idempotent
   	func warmUp() async                         // 1 s silence through the model; call on key-down
   	func transcribe(_ chunk: [Float]) async throws -> Transcript   // 16 kHz mono, 0.3–14 s
   	func unload() async
   }
   public struct Transcript: Sendable { var text: String; var confidence: Float; var tokens: [TokenTiming] }

   public actor StreamingTranscriber {
   	init(engine: any SpeechEngine, vad: VadManager, policy: ChunkPolicy = .dictation)
   	func append(_ samples: [Float]) async      // from the ring buffer, any size
   	func finish() async throws -> String       // key-up: flush tail, await in-flight chunks, join
   	func cancel() async                        // Esc: drop everything
   }
   ```
3. **Chunking policy (`.dictation`).** Run Silero VAD streaming on 4096-sample
   (256 ms) hops with `minSilenceDuration` 0.5 s. Cut at every speech-end,
   hard cap 14 s, force-cut at the lowest-probability hop in the last 4 s.
   Use a fresh `TdtDecoderState` per chunk and join with a single space.
   Transcribe chunks serially on one `AsrManager`: they're 20–100× faster than
   real time. For the tail: < 0.3 s with no VAD speech since the last cut →
   skip; otherwise pad to 1 s with silence.
4. **Model lifecycle.** Compile during onboarding (17–21 s once, as the plan
   already assumes). Load at app launch (0.4 s warm) and keep it loaded. Call
   `warmUp()` on key-down so the ANE is awake before the first chunk. Unload
   (`cleanup()` + drop `AsrModels`) on a `DispatchSource` memory-pressure
   warning and reload lazily. On key-down with the model unloaded, record
   anyway and transcribe after the 0.4 s load.
5. **Memory ceiling** for the section 6 budget: idle with model warm ≤ 120 MB
   `phys_footprint` **and** ≤ 650 MB `ri_neural_footprint` (Ultra measured
   62 / 607 MB). `yap-bench` should report both, because Activity Monitor
   only shows the first.
6. **Short and empty input.** Presses under 0.3 s never reach the engine.
   Treat an empty transcript as "didn't catch that", not as an error.
7. **Dictionary.** Build it as text post-processing (replacements plus a
   Swedish-aware fuzzy match on known terms). Keep CTC boosting behind a flag,
   and if we use it, go through `ctcTokenEvaluateCandidates` so yap decides
   which replacements to apply (for example, never change a word that the
   dictionary term only matches as a prefix). Running it per chunk while
   talking keeps its ~145 ms off the key-up path.
8. **Cleanup.** Collapse the occasional double period ("grannar..") that
   Parakeet emits on clips longer than one window.

## Open issues

- **Real speech.** Everything here is read speech (FLEURS) or TTS. We still
  need a recorded fixture set of spontaneous Swedish dictation, real
  sv/en code-switching, and AirPods vs built-in mic before setting the
  `yap-bench` WER baseline.
- **Norwegian and Danish.** Not tested whether a Norwegian speaker gets
  Swedish or Danish spelling (FluidAudio reports 20.2 % WER for Danish).
- **ANE compile cache.** Not verified whether the cache survives OS updates
  or cache purges. If not, a surprise 17–21 s compile at launch needs UI.
- **Swedish vocabulary boosting.** The CTC tokenizer is English-only. Terms
  with å/ä/ö were not tested.
- **Hardware.** Only an M3 Pro was measured. Check an M1 / base chip before
  fixing the p95 budget.
- **Notes pipeline.** ANE contention with two live tracks plus diarization
  was not measured.
- **Library alternatives not evaluated.** FluidAudio's
  `SlidingWindowAsrManager` (volatile/confirmed pseudo-streaming, useful for
  the live notes transcript) and the Nemotron multilingual streaming model
  (~40 languages, possibly covering Norwegian).
- SwiftPM prints `Internal Error: DecodingError.dataCorrupted … Corrupted JSON`
  while building FluidAudio. The build still succeeds.

## Reproduce

From `spikes/asr/` (needs `python3`, `ffmpeg`, network, ~1.3 GB of disk, ~15
min). Everything goes to `spikes/asr/.local/` (git-ignored) and each step's
stdout to `.local/results/<step>.log`:

```bash
cd spikes/asr
./scripts/reproduce.sh                       # everything below
./scripts/reproduce.sh probes breakdown      # or single steps: setup models extras probes breakdown
```

Individual commands:

```bash
python3 scripts/fetch_fleurs.py .local/data 30 sv_se en_us   # streams FLEURS test tarballs, keeps 30 clips each
./scripts/make_codeswitch.sh .local/data/codeswitch          # synthetic sv+en clips (macOS `say`, Alva)
swift build -c release
B=.build/release/asr-bench
$B download --model v3                      # also: --model ultra
$B load --model v3                          # 1st run after download = cold ANE compile, 2nd = warm
$B bench --model v3 --lang sv_se            # --lang en_us | codeswitch, optional --hint sv
$B long --model v3 --offset 0               # long clip a; --offset 11 for clip b
$B idle --model v3
$B vocab --model v3 --lang codeswitch --terms "deploya,staging,pull request,React,npm,Kubernetes,Datadog,roadmap,reviewa,backlog,branch,cachen"
$B transcribe --model v3 --file some.wav
python3 scripts/wer_breakdown.py .local/results/v3-sv_se-nohint.tsv 0 11
```

To force another cold compile, copy `.local/Models` somewhere new and point
`ASR_BENCH_MODELS` at the copy. With `ASR_BENCH_HOLD=30`, `load` keeps the
model loaded so `footprint <pid>` can inspect it.
