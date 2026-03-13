# CLAUDE.md

## Project Overview

Voice Thing is a privacy-first desktop app for capturing voice notes and meeting recordings, with automatic transcription and AI-powered structuring.

## Tech Stack

- **Framework:** Tauri v2 (Rust backend + web frontend)
- **Frontend:** React 19, TypeScript, Tailwind CSS v4, Vite
- **State:** Zustand
- **Storage:** SQLite (via tauri-plugin-sql) + filesystem for audio files
- **Transcription:** whisper.cpp via whisper-rs (planned)
- **AI:** Claude API for structuring (planned), local LLM support later

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
  components/        # UI components
  pages/             # Route pages
  hooks/             # React hooks
  stores/            # Zustand stores
  styles/            # CSS
src-tauri/           # Rust backend
  src/
    lib.rs           # Tauri app setup + plugin registration
    main.rs          # Entry point
    commands.rs      # Tauri IPC commands
```

## Code Style

- TypeScript with strict mode
- No semicolons
- Tab indentation
- Single quotes
- `import * as React from 'react'`
- Path alias: `@/` maps to `src/`
