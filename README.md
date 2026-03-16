# yap

System-wide push-to-talk dictation for macOS. Hold a key, speak, release — transcribed text gets pasted wherever your cursor is.

Everything runs locally. No cloud, no API keys, no data leaves your machine.

## Features

- **Push-to-talk** — hold Right Option (or any configured key) to dictate
- **Double-tap to lock** — hands-free recording without holding the key
- **Local transcription** — powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp), runs on-device with Metal acceleration
- **Auto-paste** — transcribed text is pasted directly into the active field
- **Multiple styles** — formal, natural, casual, or dev mode (optimized for coding prompts)
- **15 languages** — Swedish, English, German, French, Spanish, and more
- **Floating overlay** — minimal status badge that stays on top of all windows
- **Tray icon** — runs in the background, accessible from the menu bar

## Install

Download the latest `.dmg` from [Releases](../../releases).

### Requirements

- macOS 13+
- Accessibility permission (for hotkey detection + paste simulation)
- Microphone permission

## Build from source

```bash
# Prerequisites: Rust, Bun (or npm/pnpm)
bun install
bun run tauri build
```

The app bundle will be in `src-tauri/target/release/bundle/`.

### Development

```bash
bun install          # install frontend dependencies
bun run tauri dev    # start dev mode with hot reload
```

## How it works

1. A global hotkey listener (CGEventTap) detects key press/release
2. While held, audio is captured from the microphone via cpal
3. On release, audio is transcribed locally using whisper.cpp
4. Transcribed text is placed on the clipboard and pasted via simulated Cmd+V

All processing happens on your machine. The only network request is downloading the Whisper model on first setup (from Hugging Face).

## Privacy

- **No cloud APIs** — transcription runs 100% locally via whisper.cpp
- **No telemetry** — zero analytics, tracking, or phone-home
- **Text-only storage** — dictation history is stored in a local SQLite database, no audio is saved
- **No accounts** — no sign-up, no login

## Tech stack

- [Tauri v2](https://tauri.app) — Rust backend + web frontend
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via whisper-rs — local transcription
- React 19 + TypeScript + Tailwind CSS v4 — frontend
- Zustand — state management
- SQLite — local storage

## License

[MIT](LICENSE)
