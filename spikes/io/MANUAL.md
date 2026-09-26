# yapio: manual steps

These steps need a person at the keyboard or a TCC grant. Run them from `spikes/io` in
Terminal.app. Grants go to whichever app runs the CLI, so after granting, quit and reopen
Terminal.

```sh
cd spikes/io
swift build
./.build/debug/yapio perms          # what this process has right now
```

## Permission walls hit during the spike (exact output)

Before any grant (the CLI ran under Claude Code):

```
$ ./.build/debug/yapio hotkey --active --selftest
  RESULT: CGEvent.tapCreate returned nil after 31.6 ms -> permission missing (Accessibility)
$ ./.build/debug/yapio hotkey --selftest
  tap created in 26.1 ms
  RESULT: tap created but cannot post synthetic events (no Accessibility); run interactively instead
$ ./.build/debug/yapio systap
  global tap (exclude self) + afplay: callbacks 210, first after 474.8 ms, frames 215040, rms -inf dBFS (silent), peak 0.0000 -> tap-global.wav
  RESULT: global capture is silent -> System Audio Recording permission missing or denied
```

Later in the session Microphone, Accessibility and Input Monitoring were granted to the
calling app, and the hotkey, mic and insertion tests passed. System audio passed only from
the app bundle (step 2).

## 1. Grant the CLI (Terminal)

System Settings → Privacy & Security:
- **Accessibility** → add/enable Terminal
- **Input Monitoring** → enable Terminal (only for the listen-only test)
- **Microphone** → Terminal gets a prompt on first `yapio mic`

Check: `./.build/debug/yapio perms` should say `Accessibility ... true`,
`Input Monitoring ... true`, `Microphone ... authorized`.

## 2. System audio (needs the app bundle)

```sh
./make-app.sh
open -W --stdout "$PWD/.local/logs/systap-app.txt" .local/yapio.app --args systap --all
cat .local/logs/systap-app.txt
./.build/debug/yapio wavstat .local/tap-global.wav .local/tap-only-afplay.wav
```

On the first run macOS asks whether "yapio" may record system audio. Allow it. If you miss
the prompt: System Settings → Privacy & Security → **Screen & System Audio Recording** →
"System Audio Recording Only" → enable yapio. Expected: the global tap and "tap only afplay"
lines show a dBFS value, not `-inf`, and the exclusion probe shows `callbacks 0`.

## 3. Real Fn / right ⌥ keys (latency, external keyboards)

```sh
./.build/debug/yapio hotkey --active --seconds 30
```

In those 30 s: hold Fn about 1 s, double-tap Fn and tap again, hold Fn and press Esc, hold
right ⌥ and type a letter (should say `cancel`). Expected: `start/stop`, `start/lock/stop`,
`start/cancel`, `start/cancel`, plus a `callback latency` line in ms (tell us the median). Then
repeat on an external keyboard (Apple Magic Keyboard with Globe, and one third-party
keyboard). Many third-party keyboards never send Fn.

## 4. Fn usage setting mapping

For each value of System Settings → Keyboard → "Press 🌐 key to", run
`defaults read com.apple.HIToolbox AppleFnUsageType` and note the number. Expected:
0 = Do Nothing, 1 = Change Input Source, 2 = Show Emoji & Symbols, 3 = Start Dictation.
Set it back to what you had.

## 5. Hotkey under secure input

Turn on Terminal → Secure Keyboard Entry, then run step 3 in a *second* terminal window.
Does holding Fn still print `flagsChanged fn down`? Turn Secure Keyboard Entry off afterwards.

## 6. Insertion into other apps

For each target app (Chrome text box, Slack, VS Code, Notes, a Safari password field), run

```sh
./.build/debug/yapio insert --focused --delay 3
```

and click into the field within 3 s. It inserts " [yap]" the way yap would: AX first
(verified by reading the value back), then ⌘V with clipboard restore. Expected output ends
with `RESULT: inserted via AX`, `RESULT: pasted via ⌘V … data requested after N ms`, or, for
the password field, `RESULT: secure field / secure input -> nothing inserted`. Note the
result and N for each app.

## 7. AirPods / Bluetooth policy

Connect AirPods (set as default input), play music, then:

```sh
./.build/debug/yapio devices
./.build/debug/yapio mic --builtin --record 5 --name pinned-builtin
```

Expected: `policy -> capture from … MacBook Pro Microphone`, `capturing from device … MacBook
Pro Microphone`, and the music does **not** drop to phone quality. Then try
`--vp` as well and note whether the music drops (VP ignores pinning).

## 8. Voice processing in a real call

Start a Zoom/Meet call on the built-in speakers and run
`./.build/debug/yapio calls --seconds 30` (it should print `mic START … us.zoom.xos` or the
browser helper). Then, while the other side talks, run
`./.build/debug/yapio mic --record 10 --vp --name call-vp` and say whether their voice got
quieter for you (ducking). Listen to `.local/call-vp.wav`.

## 9. VP quality for dictation

```sh
./.build/debug/yapio mic --record 10 --name dict-raw       # read a paragraph
./.build/debug/yapio mic --record 10 --vp --name dict-vp   # same paragraph
```

Run both through the speech spike (Parakeet) and compare WER.

## Cleanup

```sh
pkill -f yapio; pkill afplay
rm -rf .build .local/yapio.app
```

Remove Terminal/yapio from the privacy lists if you don't want to keep the grants.
