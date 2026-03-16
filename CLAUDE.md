# CLAUDE.md

## Project Overview

Voice Thing is a system-wide push-to-talk dictation tool. Hold a hotkey, speak, release — transcribed text gets pasted into the active field.

## Tech Stack

- **Framework:** Tauri v2 (Rust backend + web frontend)
- **Frontend:** React 19, TypeScript, Tailwind CSS v4, Vite
- **State:** Zustand
- **Storage:** SQLite (via tauri-plugin-sql) — text only, no audio files
- **Transcription:** whisper.cpp via whisper-rs (local, on-device)
- **Hotkey:** rdev (global key detection)
- **Paste:** arboard (clipboard) + osascript (Cmd+V simulation)

## Commands

```bash
bun install          # Install frontend dependencies
bun run dev          # Start Vite dev server (frontend only)
bun run tauri dev    # Start full Tauri app (requires Rust)
bun run tauri build  # Build production app
```

## Architecture

```
src/                 # React frontend
  components/        # UI components (shadcn)
  pages/             # Route pages (home, settings, overlay)
  stores/            # Zustand stores (dictation-store)
  styles/            # CSS
  lib/               # DB, settings, tray
src-tauri/           # Rust backend
  src/
    lib.rs           # Tauri app setup, overlay window, dictation init
    main.rs          # Entry point
    commands.rs      # Tauri IPC commands
    dictation.rs     # Orchestrator: hotkey → mic → whisper → paste
    hotkey.rs        # Global hotkey via rdev
    mic_capture.rs   # Microphone recording via cpal
    paste.rs         # Clipboard + paste simulation
    transcribe.rs    # Whisper transcription
    model.rs         # Model download/management
```

## Code Style

- TypeScript with strict mode
- No semicolons
- Tab indentation
- Single quotes
- Path alias: `@/` maps to `src/`
