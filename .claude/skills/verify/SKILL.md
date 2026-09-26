---
name: verify
description: Verify the running yap app, not just the build. Use after changing the app target (menu bar, notch overlay, windows) to launch it, drive the overlay through its states, capture screenshots and check focus, Spaces and idle CPU.
---

# Verify yap

Build, launch, drive, capture, clean up. Everything here worked on macOS 26.1
with Xcode 26.1 on an M3 Pro with a notched built-in display plus an external
display.

## Build and launch

```bash
make app     # xcodegen generate + Debug build into build/ (zero warnings expected)
make run     # same, then quits any running yap and opens build/.../yap.app
```

Ignore these build lines, they are tool noise, not warnings in our code:
`IDERunDestination: Supported platforms ... is empty`,
`appintentsmetadataprocessor ... Metadata extraction skipped`, and an
occasional `Internal Error: DecodingError.dataCorrupted` (build still succeeds).
Xcode also notes `Disabling hardened runtime with ad-hoc codesigning`: the
setting is on and takes effect once a real signing identity is used.

Check Release too when touching `#if DEBUG` code:
`xcodebuild -project yap.xcodeproj -scheme yap -configuration Release -derivedDataPath build build`.

## Drive the overlay

DEBUG builds only. In the menu bar menu: Debug → Cycle overlay states,
Rapid-fire overlay states, or a single state. Headless, run the binary with
launch arguments (see `App/Sources/Debug/OverlayDemo.swift`):

- `-YapDebugOverlay listening|working|done|recording|cycle|rapid`
- `-YapOverlayScreen notch|plain` pins the notch to a screen with or without a
  hardware notch (default: the screen with the pointer)
- `-YapOpenWindows YES` opens History and Settings at launch

## Screenshots

`screencapture` fails ("could not create image from display") unless the
calling process has Screen Recording permission, and the computer-use tools
can't target yap (an accessory app in `build/`) and filter its windows out of
screenshots. Use the in-app capture instead, which needs no permission:

```bash
APP=build/Build/Products/Debug/yap.app/Contents/MacOS/yap
$APP -YapProbe /tmp/yap-probe -YapOverlayScreen notch -YapOpenWindows YES &
# quits by itself after ~12 s; add -YapProbeStay YES to keep it running
cat /tmp/yap-probe/probe.txt
```

The probe (`App/Sources/Debug/OverlayProbe.swift`) shows every state on the
live panel, writes `live-<state>.png` of the real panel content,
`live-menubar-item.png`, `live-window-<title>.png`, then rapid-fires 80
random states and checks that done closes on its own. `probe.txt` has, per
state: visibility, `onActiveSpace`, occlusion, frame, screen, notch size,
`key`, `yapActive` and the frontmost app.

`-YapSnapshots <dir>` renders every state over a stand-in desktop with
`ImageRenderer` (notched and plain), for design review.

What good looks like: `key=false` and `front=` unchanged in every state (the
panel never takes focus; `yapActive` only turns true when `-YapOpenWindows`
activated the app), `visible=true onActiveSpace=true occluded=false` while
shown, `visible=false` after hidden, after-rapid and done-auto-dismiss.

To check full-screen apps: put another app in full screen on the notched
display (Preview with any PNG works; click its green button through the
computer-use `app_click`), then run the probe with `-YapOverlayScreen notch`.
Don't commandeer windows other agents are using (e.g. TextEdit spike docs).

## End-to-end dictation

Real mic, real model, real insertion. **Safety first:** synthetic keys and
inserted text may only ever reach a window you opened for the test. Never
post a key unless the frontmost app *and* its focused window are yours
(`yapkey` checks both right before every event and refuses otherwise).

Permissions: `make run` launches through LaunchServices, so the ad-hoc build
is its own TCC identity and has nothing; the menu then shows "Needs
Microphone and Accessibility" and a Grant access item (check this, but don't
click it: it prompts the user). For dictation, launch the binary directly
from the shell instead; it inherits the shell's Microphone, Accessibility and
Post Events grants.

Tools (sources in `tools/`, build once into a scratch dir):

```bash
T=<scratch>/tools; mkdir -p $T
for t in yapkey axdoc clip notify; do swiftc -O .claude/skills/verify/tools/$t.swift -o $T/$t; done
```

- `yapkey <bundle> <title> fn-down|fn-up|ropt-down|ropt-up|esc|pastelast`
  posts one event after checking focus. It waits 150 ms before exiting: a
  poster that exits right after `CGEvent.post` sometimes loses the event
  (seen as a lost release, which leaves yap listening).
- `axdoc <bundle> <title> front|text|clear` checks focus, reads or clears
  the window's text area through AX. Don't script TextEdit with AppleScript:
  it pops an Automation consent dialog on the user's screen.
- `clip save|restore <file>` / `clip read`: snapshot the user's clipboard
  before probing and restore it after anything that leaves text on it.
- `notify <name>` posts yap's Debug distributed notifications:
  `com.bjornbom.yap.debug.tryIt` opens the Try it window,
  `com.bjornbom.yap.debug.captureWindows` writes visible windows to PNG.

Recipe:

```bash
APP=build/Build/Products/Debug/yap.app/Contents/MacOS/yap
$T/clip save <scratch>/clipboard.plist
$APP -YapHistoryPath <scratch>/history.sqlite -YapCaptureDir <scratch>/cap -YapOverlayScreen notch &
: > <scratch>/yap-verify-doc.txt; open -a TextEdit <scratch>/yap-verify-doc.txt
$T/axdoc com.apple.TextEdit yap-verify-doc front          # must pass
$T/yapkey com.apple.TextEdit yap-verify-doc fn-down && sleep 0.25
say -v Alva "Kan du skicka rapporten till Anna innan lunch?"
sleep 0.4; $T/yapkey com.apple.TextEdit yap-verify-doc fn-up
sleep 1.5; $T/axdoc com.apple.TextEdit yap-verify-doc text
/usr/bin/log show --last 1m --style compact --info --predicate 'subsystem == "com.bjornbom.yap"'
```

- `-YapHistoryPath` keeps test dictations out of the real history.
- `-YapCaptureDir` writes every notch state the app shows to
  `NN-<state>.png` (listening three times, so real levels show; working
  right away, it lasts ~100 ms warm).
- The log has `Status: …` on every menu status change and
  `Key-up to <outcome>: <ms> ms` per dictation (`zsh` has a `log` builtin,
  hence `/usr/bin/log`). Add `--debug` for `Hotkey start/stop/cancel`.
- Probes: Esc between fn-down and fn-up (nothing inserted); fn-down, 0.1 s,
  fn-up (nothing); `-YapModelDelay 15` then press ("Getting ready…");
  focus moved: after fn-down, `notify com.bjornbom.yap.debug.tryIt` plus
  `open build/.../yap.app` (macOS refuses self-activation from the
  background) and release with `yapkey com.bjornbom.yap "Try it" fn-up`:
  nothing typed, text on the clipboard, "You switched apps." in the notch;
  `pastelast` with the doc frontmost. Switch the trigger in Settings through
  System Events (`pop up button "Push to talk"` in window "yap Settings"),
  then use `ropt-down`/`ropt-up`; switch it back to fn afterwards, since
  UserDefaults are shared with the user's own yap.
- A locked history: hold `BEGIN EXCLUSIVE` on the `-YapHistoryPath` file
  with `sqlite3` for 20 s; dictation still inserts, the log shows retries,
  then `History open`.
- Windows: `screencapture` needs Screen Recording; `captureWindows` asks the
  window server for yap's own windows instead, which needs no permission.

Close only your own document afterwards and restore the clipboard.

## Idle CPU

```bash
ps -o cputime= -p $(pgrep -x yap); sleep 10; ps -o cputime= -p $(pgrep -x yap)
```

Expect no change with the notch hidden. While listening it is ~7% (30 fps
redraw); the shimmer runs at 60 fps. Memory with the model warm:
`footprint $(pgrep -x yap)` (M1: 56 MB footprint, 579 MB `neural`).

## Quit and clean up

Menu: Quit yap. Headless: `pkill -x yap`, then `pgrep -x yap` must print
nothing. Close any app windows you opened for probing. `make clean` removes
`build/` and the generated project; do it before removing a worktree.
