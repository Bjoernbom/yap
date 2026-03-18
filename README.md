# yap

talk to your computer. it types for you.

hold a key, say words, let go — text shows up wherever your cursor is. no cloud, no accounts, no bs. everything runs on your machine.

## what it does

- **hold to yap** — press any key (or combo like ⌘R), talk, release. text gets pasted instantly
- **double-tap to lock** — hands-free mode, keep yapping without holding anything
- **actually private** — whisper.cpp runs locally on your mac. nothing leaves your machine. ever
- **polish mode** — paste your claude api key and yap cleans up your speech automatically. removes filler words, fixes punctuation, keeps your voice
- **vibes** — proper, natural, chill, or dev mode. only available with polish — because whisper doesn't care about vibes
- **custom triggers** — any single key, modifier, or combo (⌥R, ⌘⇧R, F5, whatever)
- **15 languages** — english, swedish, german, french, spanish, and more
- **notch overlay** — sits at the top of your screen like a notch extension. pixel font because we're cool like that
- **auto-updates** — the app checks for new versions and installs them with one tap
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

### polish (optional)

paste a [claude api key](https://console.anthropic.com/) in settings to unlock:
- automatic cleanup of filler words (um, uh, like)
- punctuation and capitalization fixes
- vibe modes (proper, natural, chill, dev)

your key stays local. only talks to anthropic's api.

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

```
you talk → whisper transcribes → (optional) claude polishes → text gets pasted
```

1. global hotkey listener (CGEventTap) catches your trigger key/combo
2. mic records while you hold the key
3. whisper.cpp transcribes locally (metal accelerated)
4. if polish is on: claude cleans up the text (~1s)
5. text hits clipboard → simulated Cmd+V → pasted

only network requests: whisper model download (first setup) and claude api calls (if polish is enabled). everything else is local.

## privacy

- **transcription is local** — whisper.cpp, on your machine, no cloud
- **no telemetry** — zero tracking, zero analytics
- **no audio saved** — text only, stored in local sqlite
- **no accounts** — no sign up, no login, no email
- **polish is opt-in** — if you add an api key, transcribed text is sent to anthropic for cleanup. nothing else

## stack

- [tauri v2](https://tauri.app) — rust backend + web frontend
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — local speech-to-text
- [claude](https://anthropic.com) — optional text polish (haiku 4.5)
- react 19 + typescript + tailwind v4
- pixelify sans — brand font because pixels are cool
- zustand + sqlite — state + storage

## license

[MIT](LICENSE)
