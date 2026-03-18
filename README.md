# yap

talk to your computer. it types for you.

hold a key, say words, let go — text shows up wherever your cursor is. no cloud, no accounts, no bs. everything runs on your machine.

## what it does

- **hold to yap** — press your trigger key, talk, release. text gets pasted instantly
- **double-tap to lock** — hands-free mode, keep yapping without holding anything
- **actually private** — whisper.cpp runs locally on your mac. nothing leaves your machine. ever
- **multiple vibes** — proper, natural, chill, or dev mode (built for coding prompts)
- **15 languages** — english, swedish, german, french, spanish, and more
- **tiny overlay** — floating pixel badge that stays on top of everything
- **lives in your menu bar** — always running, never in the way

## install

grab the `.dmg` from [releases](../../releases).

### heads up

not code-signed yet (indie dev things). macos will complain. fix it once:

```bash
xattr -cr /Applications/yap.app
```

then open normally. you'll never see that again.

### first launch

the app walks you through everything:
1. pick your language
2. grant accessibility + mic permissions
3. download the whisper model (~1.6 GB, one time)
4. start yapping

## build from source

```bash
bun install
bun run tauri build
```

output lands in `src-tauri/target/release/bundle/`.

### dev mode

```bash
bun install
bun run tauri dev
```

## how it works

1. global hotkey listener (CGEventTap) catches your trigger key
2. mic records while you hold the key
3. whisper.cpp transcribes locally (metal accelerated)
4. text hits clipboard → simulated Cmd+V → pasted

only network request: downloading the whisper model on first setup. that's it.

## privacy

- **no cloud** — transcription is 100% local
- **no telemetry** — zero tracking, zero analytics
- **no audio saved** — text only, stored in local sqlite
- **no accounts** — no sign up, no login, no email

## stack

- [tauri v2](https://tauri.app) — rust backend + web frontend
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — local speech-to-text
- react 19 + typescript + tailwind v4
- pixelify sans — brand font because pixels are cool
- zustand + sqlite — state + storage

## license

[MIT](LICENSE)
