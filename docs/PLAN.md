# yap 1.0 — rewrite plan

> talk. it types. and it takes notes.

yap 1.0 is a from-scratch rewrite. It keeps the name, the notch and the pixel
soul, and does exactly two things, extremely well:

1. **Dictate** — hold a key, talk, let go. Text lands where your cursor is.
2. **Notes** — record a meeting. Get a transcript, a summary and action items.

Everything runs on the Mac. No API keys, no accounts, no cloud, no telemetry.

---

## 1. Principles

- **Two features, zero fluff.** If it isn't dictation or notes, it's not in 1.0.
- **Fast enough to feel like magic.** Latency is a feature; we measure it in CI.
- **Never lose words.** Every transcript is saved before anything else happens.
  If insertion fails, the text is on the clipboard and the user is told.
- **Zero configuration.** No language picker, no model picker, no style picker by
  default. Good defaults, one screen of settings.
- **Local, for real.** Speech and language models run on-device. The only
  network calls are the one-time model download and update checks.
- **Native.** It should feel like Apple shipped it, with a bit of attitude.

## 2. What changes vs 0.4

| 0.4 (today)                                   | 1.0                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------- |
| Tauri + React + webview, Rust glue            | Native Swift 6 + SwiftUI/AppKit. No webview, ~10 MB app             |
| whisper.cpp, pick model (75 MB–1.6 GB)        | Parakeet TDT v3 on the Neural Engine. One model, no choice needed   |
| Pick a language (15)                          | Auto-detects 25 European languages. Optional Whisper for no/ja/zh/ko |
| Transcribe after release                      | Transcribe *while* you talk. Release → text in < 300 ms, any length |
| Polish via Claude API key                     | Polish via Apple Foundation Models, on-device, free                 |
| Pick a "vibe" manually                        | Style follows the app you're in (Slack, Mail, Xcode, Terminal…)     |
| Clipboard + osascript ⌘V, clipboard lost      | Accessibility insert, paste fallback, clipboard restored            |
| Unsigned, `xattr -cr` workaround              | One-line install, stable signing, Sparkle updates, Homebrew cask    |
| No meeting notes                              | Notes: mic + system audio, speakers, summary, Markdown files        |

## 3. Tech stack

| Concern             | Choice                                                                 | Why                                                                                   |
| ------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Language / UI       | Swift 6, SwiftUI + AppKit (`NSPanel` for the notch, `MenuBarExtra`)   | Lowest latency and memory, native look, no JS bridge                                  |
| Platform            | macOS 26+, Apple Silicon only                                          | Unlocks Foundation Models + Neural Engine; removes every fallback path                |
| Speech-to-text      | [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet TDT v3 (Core ML, ANE) | Much faster than Whisper on ANE, punctuation + casing built in, multilingual auto-detect |
| Extra languages     | [WhisperKit](https://github.com/argmaxinc/WhisperKit) large-v3-turbo, optional download | Covers Norwegian, Japanese, Chinese, Korean that Parakeet v3 lacks                     |
| VAD + diarization   | FluidAudio (Silero VAD, speaker diarization on Core ML)                | Same SDK, same runtime, on the ANE                                                     |
| Polish + summaries  | Apple Foundation Models (`LanguageModelSession`, `@Generable`)         | On-device, free, zero download, structured output for action items                    |
| Mic capture         | `AVAudioEngine` with voice processing (echo cancellation)             | AEC keeps speaker bleed out of "you" in meetings                                       |
| System audio        | Core Audio process taps (`CATapDescription`)                           | Captures call audio without a virtual driver or Screen Recording permission           |
| Hotkey              | Own `CGEventTap` state machine                                         | Needed for modifier-only push-to-talk (Fn, right ⌥) and double-tap lock               |
| Text insertion      | AX `kAXSelectedTextAttribute` → fallback `CGEvent` ⌘V + clipboard restore | Native fields get text directly; everything else still works; clipboard survives   |
| Storage             | [GRDB](https://github.com/groue/GRDB.swift) + SQLite FTS5 for history; notes as `.md` files | Fast search; notes are plain files that work with Obsidian, iCloud, git            |
| Updates             | [Sparkle 2](https://sparkle-project.org)                               | EdDSA-verified updates; works without a paid Apple account                           |
| Project             | [XcodeGen](https://github.com/yonaskolb/XcodeGen) `project.yml` for a thin app target + one Swift package (`YapKit`) | Logic is testable with `swift test`; no committed `.pbxproj`, no merge conflicts |

## 4. Architecture

```
yap.app
├─ App/           menu bar, onboarding, settings, notes window, history
├─ Overlay/       notch NSPanel + pixel waveform (Canvas, 60 fps, ~0% idle CPU)
└─ YapKit/        (Swift package, no UI)
   ├─ Input/      HotkeyMonitor — CGEventTap → press/release/double-tap/cancel
   ├─ Audio/      MicCapture, SystemAudioTap, DevicePolicy, RingBuffer
   ├─ Speech/     SpeechEngine protocol → ParakeetEngine, WhisperEngine
   │              StreamingTranscriber (VAD-chunked), Diarizer
   ├─ Text/       Cleanup (fillers, spacing), Dictionary, AppContext, Polisher
   ├─ Output/     Inserter (AX → paste, clipboard restore, secure-field detection)
   ├─ Dictation/  DictationSession — one explicit state machine
   ├─ Notes/      NotesSession, CallDetector, Summarizer, MarkdownWriter
   └─ Store/      History (GRDB), Settings
```

**Dictation pipeline**

```
key down ─▶ mic on ─▶ 16 kHz ring buffer ─▶ VAD cuts at pauses ─▶ Parakeet per chunk (while talking)
key up   ─▶ flush last chunk ─▶ join ─▶ cleanup + dictionary ─▶ polish (optional, 1.5 s timeout)
         ─▶ save to history ─▶ insert into focused app ─▶ restore clipboard
```

Chunking during speech is the key trick: a 2-minute ramble pastes as fast as a
2-second one, because only the last chunk is left when you let go.

**Notes pipeline**

```
start ─▶ mic (AEC, "you") + system tap ("them") as two tracks ─▶ live transcript per track
stop  ─▶ diarize "them" into speakers ─▶ merge by timestamp
      ─▶ Foundation Models: title, summary, decisions, action items (chunked map-reduce)
      ─▶ write ~/Documents/yap/2026-10-02 Design sync.md ─▶ delete audio (unless kept)
```

Two tracks give "you vs them" for free and make diarization much more accurate.
Foundation Models has a small context window, so summaries run map-reduce over
~10-minute sections, then one final pass.

## 5. The experience

### Dictate
- **Hold Fn** (default; right ⌥ as alternative) → talk → release. Text appears.
- **Double-tap** to lock hands-free; tap once to stop. **Esc** cancels, nothing is typed.
- **Auto style by app.** Messaging → casual; Mail/Docs → proper; Xcode/Terminal/
  editors → dev (identifiers intact, no trailing period). Override per app.
- **Dictionary.** Your words (names, product terms) and replacements
  ("yap dot app" → yap.app). Used by cleanup and by polish.
- **Paste last** with ⌃⌘V when focus was wrong. History keeps 30 days, searchable.
- **Smart mic choice.** Prefers the built-in mic over AirPods so your music
  doesn't drop to phone quality every time you dictate.
- **Secure fields.** Password fields get nothing; yap says so and keeps the text.

### Notes
- **Start from the menu bar or ⌥⌘N.** Or let yap notice: when Zoom, Meet, Teams,
  Slack huddles or FaceTime start using the mic, the notch offers
  *"on a call? take notes"* — one click. No bot joins your meeting.
- **During:** red dot + timer in the notch. Click for the live transcript.
- **After:** a clean note — title, summary, decisions, action items, transcript
  with "you", "speaker 1", "speaker 2" (rename once, it sticks for that note).
- **Plain files.** Markdown in a folder you choose. Copy as Markdown in one click.
- **Consent nudge.** First time only: a short line reminding you to tell people
  you're taking notes.

### Onboarding (60 seconds)
1. Hi — model download starts immediately in the background.
2. Permissions — Microphone and Accessibility, each with a live green check.
   System audio is asked only the first time you take notes.
3. Pick your key (Fn is preselected). If Fn opens the emoji picker, we show the fix.
4. **Try it** — a text box. Hold, say something, let go. That's the aha moment.
   The model finishes compiling for the Neural Engine while you do this.

### Settings (one screen)
Shortcut · Microphone · Polish on/off · Styles per app · Dictionary ·
Notes folder · Keep meeting audio · Extra languages · Launch at login.
Plus a **Health** row: every permission and the model, green or with a fix button.

## 6. Performance budgets (checked by `yap-bench` in CI)

| Metric                                           | Target            |
| ------------------------------------------------ | ----------------- |
| Key down → recording                             | < 50 ms           |
| Key up → text inserted, no polish (p95)          | < 300 ms          |
| Key up → text inserted, with polish (p95)        | < 1.2 s           |
| Idle CPU                                         | ~0 %              |
| Idle memory, model warm                          | measure in M0, then set a ceiling |
| App download (without models)                    | < 15 MB           |
| Word error rate, sv + en fixtures                | ≤ 0.4 (whisper medium), never regresses |
| 60-min meeting → finished note after stop        | < 60 s            |

`yap-bench` is a small CLI in the package: runs recorded fixtures through the
pipeline and reports latency and WER, so every PR shows whether it got faster.

## 7. Brand, UX, voice

**Keep:** the name *yap*, always lowercase. The black notch. Pixels. The verb
"yap". It's still a bit cheeky.

**Evolve:** from gen-z joke to confident tool. Fewer words, more craft. It
should read like it was made by one sharp person who cares — because it was.

### Visual
- **Signature element: the pixel waveform.** While you talk, the notch shows a
  waveform made of chunky pixel bars. It's the brand and the feedback in one.
- **Pixel font only for brand moments:** the wordmark, the notch timer, and
  big numbers. All functional UI uses SF Pro, so it feels native and reads fast.
- **Colour:** black and white, plus one accent. Proposal: *signal lime*
  (`#C8FF3D`) for "listening", red strictly for "recording a meeting".
  Nothing else gets colour.
- **Motion:** the notch grows out of the hardware notch (spring, ~200 ms) and
  shrinks back. A soft tick sound on start/stop (can be turned off).
- **Icon:** refresh the pixel icon for the macOS 26 layered icon style.

### Voice
- Short. Lowercase for brand moments (headlines, notch, README), sentence case
  for anything you need to act on (settings, errors, permissions).
- Say what happened and what to do. One line. No apologies, no exclamation marks.
- Humour is seasoning: one small wink per screen at most.
- Retire: "cooking", "no bs", "we're cool like that", "indie dev things".

| Where            | 0.4                         | 1.0                                              |
| ---------------- | --------------------------- | ------------------------------------------------ |
| Tagline          | talk to your computer. it types for you. | talk. it types.                     |
| Notch, listening | yapping                     | *(pixel waveform, no word)*                      |
| Notch, working   | cooking                     | *(waveform folds into a shimmer)*                |
| Notch, done      | yapped                      | *(tick, then gone)*                              |
| Paste failed     | oops                        | Couldn't type here. It's on your clipboard.      |
| Call detected    | —                           | on a call? take notes                            |
| Privacy line     | no cloud, no accounts, no bs | Runs on your Mac. Nothing leaves it.            |
| About            | —                           | yap is made by bjornbom. Open source, MIT.       |

### Personal brand
- README opens with one first-person line from me on why yap exists, then a
  demo GIF of the notch, then install. Short enough to read in a minute.
- "made by bjornbom" in About and the README footer, linking to my profile.
- A single landing page (same visual system) with the download button and the GIF.

## 8. Shipping it so it "just works"

No paid Apple Developer account. Everything in the app works without one; the
only thing it buys is notarization, which removes a one-time warning on first
launch for people who download the DMG in a browser. We design around that and
keep Developer ID as a drop-in upgrade (CI secrets only, no code changes).

- **Stable self-signed code signing.** CI signs every build with the same
  self-signed certificate (hardened runtime on). A stable signature means macOS
  keeps Microphone and Accessibility permissions across updates. Ad-hoc signing
  changes identity every build and silently revokes them.
- **Install, primary:** one line, zero warnings — files fetched with `curl` get
  no quarantine flag, so Gatekeeper never interrupts:
  `curl -fsSL https://github.com/Bjoernbom/yap/releases/latest/download/install.sh | sh`
  The script is short and readable: download, verify checksum, move to
  `/Applications`, open.
- **Install, Homebrew:** own tap (`brew install --cask bjornbom/tap/yap`) whose
  cask strips quarantine on install. Secondary path; Homebrew is tightening
  rules for unnotarized casks.
- **Install, DMG:** for manual downloads, with a clear one-image guide to
  System Settings → Privacy & Security → Open Anyway (macOS 15+ removed the
  right-click → Open shortcut).
- **Updates:** Sparkle 2 with an EdDSA-signed appcast. Downloads made by the app
  itself are not quarantined, so updates install silently after the first run.
- **CI:** GitHub Actions on macOS runners — build, `swift test`, `yap-bench` on
  every PR; on tag: archive, sign, DMG, zip, checksums, appcast, release.
- **Diagnostics without telemetry:** local log + "Copy diagnostics" button that
  produces a text blob users can paste into a GitHub issue.
- **Bundle id:** `com.bjornbom.yap` (0.4 used `com.voicething.app`).
- **Migrating 0.4 users:** 0.4's Tauri updater reads `latest.json` from the
  latest GitHub release. Spike whether it can install the new bundle directly;
  otherwise ship a last 0.4.x that shows a one-line "yap 1.0 is out" banner.
  Until then, 1.0 pre-releases are marked as GitHub *pre-releases* so 0.4 users
  are never affected.

## 9. Milestones

| #  | Milestone          | Done when                                                                                 |
| -- | ------------------ | ----------------------------------------------------------------------------------------- |
| M0 | Spikes             | Parakeet v3 sv/en WER + latency + memory measured; Foundation Models polish/summary quality in sv/en checked; Core Audio tap + AEC capture works; Fn capture + AX insertion work. Findings in `docs/spikes/` |
| M1 | Dictation core     | Hold → talk → release inserts text in any app; notch overlay; history; streaming chunks    |
| M2 | Dictation magic    | App-aware style, cleanup, dictionary, polish with timeout, clipboard restore, paste last, double-tap lock, device policy |
| M3 | Notes              | Two-track capture, live transcript, diarization, summary, Markdown files, call detection   |
| M4 | Ship               | Onboarding, settings + health, self-signed signing, install script, Sparkle, cask, release CI, `yap-bench` |
| M5 | Brand              | Pixel waveform, icon, sounds, README, landing page, demo GIF                               |

**Repo:** same repo (`Bjoernbom/yap`), so the URL, stars, issues and the 0.4
update channel stay. `main` is wiped and restarted as 1.0; the Tauri code lives
on under the `v0.4.0` tag.

**Workflow:** one PR per logical unit, squash-merged into `main` once it builds
and its tests pass. Independent work runs in parallel git worktrees.

## 10. Not in 1.0

Windows/Linux, Intel Macs, any cloud model, accounts, meeting bots, calendar
integration, file import, "command mode" (rewrite selected text by voice), iOS.
Good ideas for later — not now.

## 11. Decisions

1. Native Swift, macOS 26+, Apple Silicon only — **yes**.
2. Paid Apple Developer Program — **no**; see section 8. Revisit if first-launch
   friction turns out to hurt adoption.
3. Accent colour and tagline — lime + "talk. it types." as working default;
   final call in M5.
4. Whisper for Norwegian/Japanese/Chinese/Korean — optional download, built
   after M3 so it never slows down the core.

## 12. Assumptions to verify in M0

- Parakeet TDT v3 quality on Swedish, and on Swedish/English code-switching.
- Foundation Models availability and quality for Swedish polish and summaries.
- FluidAudio custom-vocabulary support (else the dictionary is post-processing only).
- Voice-processing AEC doesn't degrade dictation quality (use it for notes only if it does).
- Fn/Globe capture via `CGEventTap` flagsChanged across keyboards.
