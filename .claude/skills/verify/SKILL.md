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

## Idle CPU

```bash
ps -o cputime= -p $(pgrep -x yap); sleep 10; ps -o cputime= -p $(pgrep -x yap)
```

Expect no change with the notch hidden. While listening it is ~7% (30 fps
redraw); the shimmer runs at 60 fps.

## Quit and clean up

Menu: Quit yap. Headless: `pkill -x yap`, then `pgrep -x yap` must print
nothing. Close any app windows you opened for probing. `make clean` removes
`build/` and the generated project; do it before removing a worktree.
