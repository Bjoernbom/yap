# Spike M0-IO: macOS plumbing

Machine: MacBook Pro (Apple Silicon), macOS 26.6.2, Swift 6.2.1. Code: `spikes/io`
(one CLI, `yapio <command>`). Raw captures were kept in `spikes/io/.local/logs`
(not committed). Manual follow-ups: `spikes/io/MANUAL.md`.

| Topic | Status |
| --- | --- |
| Hotkey (CGEventTap, Fn / right ⌥, double-tap, Esc) | **Works** with synthetic events; real-key latency is a manual step |
| Mic (AVAudioEngine → 16 kHz mono) | **Works**, measured; voice processing has big side effects |
| System audio (process tap) | **Works from an `.app` bundle**; silent from a bare CLI |
| Call detection | **Works**, no permission needed |
| Insertion (AX, ⌘V fallback) | **Works** in TextEdit, measured; probes done |
| Device policy | **Works** without voice processing; ignored with it |

## How TCC saw the spike

- A CLI started from a terminal (here Claude Code) inherits the terminal's TCC identity (the
  "responsible process"). Microphone, Accessibility, Input Monitoring and Post Events were
  granted to that identity during the run, so the CLI results below ran with those grants.
- Embedding an Info.plist with `-sectcreate __TEXT __info_plist` works: `Bundle.main`
  sees the bundle id and usage strings, and `codesign -dv` shows `Info.plist entries=9`. It
  does not give the CLI its own TCC identity.
- System audio from the CLI was **silent** (210 callbacks, peak 0.0000; no error code). The same
  binary wrapped in a minimal `.app` (`make-app.sh`) and started with `open` has its own
  identity and captured audio. **Conclusion: test and ship system audio from an app bundle.**
- The private `TCCAccessPreflight` SPI is not reliable for audio capture. After an ad-hoc
  re-sign it reported "not determined" (2), but capture still worked. Don't build the Health
  row on it.

## 1. Hotkey (`Input`)

Observed:
- Pure state machine: 5/5 cases pass (hold, double-tap lock + tap stop, lone tap discarded,
  Esc while holding, chord).
- Listen-only tap with synthetic events posted at `.cghidEventTap`: 9/9 expected actions.
  Active tap (`.defaultTap`): 16/16, including Esc-while-holding (swallowed), Fn+A chord
  (cancel, swallowed) and triple-tap (lock, then stop).
- Fn/Globe: `flagsChanged`, keycode 63, `.maskSecondaryFn` (0x800000). Right ⌥: keycode 61,
  `.maskAlternate` plus the device bit 0x40 (`NX_DEVICERALTKEYMASK`). Left ⌥ sets only
  `.maskAlternate`.
- `tapCreate` takes 27–30 ms.
- Without permission, an **active** tap returns nil (31.6 ms). A **listen-only** tap is
  created **even without Input Monitoring**, it just never gets events. So a nil check does
  not tell you about permissions; use `CGPreflightListenEventAccess` or `AXIsProcessTrusted`.
- `AppleFnUsageType` (domain `com.apple.HIToolbox`) is readable with
  `CFPreferencesCopyAppValue`; this Mac has 0 (Do Nothing). Mapping 1 = change input source,
  2 = emoji & symbols, 3 = dictation is from System Settings, **not verified here** (manual).

Gotchas:
- Callbacks must be fast. On `tapDisabledByTimeout` / `ByUserInput` you have to re-enable the
  tap, or the hotkey dies silently.
- Put `keyUp` in the mask too. Swallowing a `keyDown` (Esc, chord key) lets its `keyUp` leak
  to the app.
- Whether modifier `flagsChanged` still reach a tap while secure input is on is untested
  (manual).

Recommended shape:

```swift
public enum HotkeyTrigger: Sendable { case fn, rightOption }
public enum HotkeyAction: Sendable { case start, stop, lock, cancel }
public struct HotkeyStateMachine: Sendable { /* pure, as in spikes/io Hotkey.swift */ }
public final class HotkeyMonitor: Sendable {
	public init(trigger: HotkeyTrigger)
	public func actions() -> AsyncStream<HotkeyAction> // active tap on its own thread + CFRunLoop
}
```

Use an **active** tap: yap needs Accessibility anyway, and only an active tap can swallow
Esc when it cancels a dictation.

## 2. Mic (`Audio.MicCapture`)

Latency, median of 5 (min–max). "Mic live" = host time of the first captured sample minus
the moment `start()` was called:

| Config | setup | `start()` blocks | mic live | first tap buffer |
| --- | --- | --- | --- | --- |
| raw, cold (new engine) | 78 ms | 64 ms | **62 ms** (60–71) | 170 ms |
| raw, prepared | — | 48 ms | **46 ms** (40–62) | 154 ms |
| raw, restart same engine | 85 ms | 84 ms | 80 ms (62–85) | 188 ms |
| VP, cold | 348 ms | 61 ms | **59 ms** (57–65) | 168 ms |
| VP, prepared | — | 45 ms | **41 ms** (40–60) | 151 ms |

- A tap delivers **4800-frame (100 ms) buffers** whatever `bufferSize` you ask for. That adds
  about 108 ms to "first buffer", though no audio is lost. For a 60 fps waveform use
  `AVAudioSinkNode` (not measured).
- `AVAudioConverter` 48 kHz → 16 kHz mono works. With VP the input has **9 channels**, and
  channel 0 is the processed voice, so set `converter.channelMap = [0]`.
- **Swift 6 trap:** a tap closure written inside a `@MainActor` function inherits MainActor
  isolation and crashes (`dispatch_assert_queue_fail`) on AVAudioEngine's queue. Build tap
  and IOProc blocks in `nonisolated` functions.
- Unpinned, the non-VP input AU runs on `CADefaultDeviceAggregate-…`, an aggregate that
  follows the system default.

Voice processing (`setVoiceProcessingEnabled(true)`):
- Enabling it adds about 250–300 ms of setup. Do it at launch or prepare time, not on
  key-down.
- `engine.start()` fails with **-10875** ("client-side input and output formats do not
  match") if you touch `mainMixerNode`, because the mixer defaults to 44.1 kHz and the input
  runs at 48 kHz. Fix: leave the output side alone, or connect mixer → output at the input's
  sample rate.
- **Ducking:** while VP runs, other apps' audio (measured with the process tap) drops about
  30 dB, from −18 to −45…−54 dBFS. `voiceProcessingOtherAudioDuckingConfiguration(.min)` made
  no difference (set before start, after start, advanced on or off). Control run with raw mic:
  no ducking.
- **AEC:** with `say` playing from the built-in speakers, raw mic −30.8 dBFS vs VP −48.0 dBFS
  (about 17 dB removed, close to VP's floor).
- **AGC / noise:** quiet room −65 dBFS raw vs −53 dBFS with VP.
- The output device's nominal rate stayed at 48 kHz.

**Recommendation:** dictation uses the raw mic, never VP (VP ducks the user's music every
time they dictate). For notes, VP is only worth it when the output is the built-in speakers,
and the 30 dB ducking of call audio probably rules it out. Plan B: raw mic, plus using the
system-tap track as the reference to gate or attribute echo. Decide in M3 after a real call
test.

```swift
public actor MicCapture {
	public init(device: AudioDeviceID?) // nil = system default
	public func prepare() throws // engine + tap + prepare() while idle
	public func start() throws -> AsyncStream<AudioChunk> // 16 kHz mono Float32 + host time
	public func stop()
}
```

## 3. System audio (`Audio.SystemAudioTap`)

Observed (from `yapio.app`):
- Tap format: 48 kHz, 2 ch, interleaved Float32. The first callback comes 37 ms after start
  when warm, 344–475 ms the first time in a process.
- Global tap excluding self + `afplay Glass.aiff`: −20 to −33 dBFS. The WAV was read back from
  disk to confirm it is not silent.
- **Only specific processes:** `CATapDescription(stereoMixdownOfProcesses: [afplayObject])`
  gave −28.8 dBFS, i.e. only afplay.
- **Exclusion:** a global tap excluding afplay and every other process with output (Chrome was
  playing) got **0 callbacks**. Excluding yap itself is the same call with our own process
  object (`kAudioHardwarePropertyTranslatePIDToProcessObject`).
- macOS 26 `CATapDescription.bundleIDs = ["us.zoom.xos"]` creates a tap even while Zoom isn't
  running (0 callbacks).
- **Gotcha:** when nothing the tap covers is playing, the IOProc **does not run at all**. You
  get no callbacks, not silent buffers. The notes timeline must use host time and fill gaps.
- **Gotcha:** a missing permission looks like silence (callbacks with all-zero samples), not
  an error. Detect it with a heuristic: all-zero data while some process reports
  `kAudioProcessPropertyIsRunningOutput`.
- Recipe: tap → private aggregate device (`kAudioAggregateDeviceIsPrivateKey`,
  `TapAutoStart`, main sub-device = default output, tap list with drift compensation) →
  `AudioDeviceCreateIOProcIDWithBlock` → `AudioDeviceStart`. Tear down in reverse.

M3 (`SystemAudioTap`, checked with `-YapNotesProbe` in the Debug app):
- Mono tap (`monoGlobalTapButExcludeProcesses`), so the IOProc gets one channel and no
  downmix is needed. Excluding yap by bundle id (`bundleIDs`) also works before yap has
  a process object; a tap on yap's own pid is the control and hears yap's sound.
- With permission and nothing playing: 0 callbacks in 3 s. **Without permission (bare
  CLI) callbacks run even when nothing plays** (107 in 2 s), all zeros. So "callbacks
  but only zeros" is the blocked signature, and `looksBlocked` fired from the CLI.
- First callback ~740 ms after start in a fresh process (includes waiting for afplay,
  started at 500 ms). Stop/start 10× with 100 ms captures: no failures, teardown clean.
- Output device changes rebuild the aggregate in the same stream; not exercised with a
  physical device switch yet (manual).

```swift
public final class SystemAudioTap: Sendable {
	public enum Target: Sendable { case allExcept(pids: [pid_t]), processes([pid_t]), bundleIDs([String]) }
	public init(target: Target)
	public func start() throws -> AsyncStream<AudioChunk>
	public func stop()
}
```

## 4. Call detection (`Notes.CallDetector`)

- Listen to `kAudioDevicePropertyDeviceIsRunningSomewhere` on the input device(s). When it
  changes, **rescan** `kAudioHardwarePropertyProcessObjectList` and read
  `kAudioProcessPropertyIsRunningInput`, `PID` and `BundleID`.
- Observed: the device event came 260–340 ms after launching a child recorder (that includes
  the child's engine setup). The rescan named the process 11 ms later:
  `pid … yapio bundle 'com.bjornbom.yap.spike.io'`. Stop was detected the same way.
- A `kAudioProcessPropertyIsRunningInput` listener on the process object **never fired**. The
  process-list listener fires when the client is added, but at that point IsRunningInput is
  still false. Hence the rescan.
- No permission needed. Exclude yap's own pid. Browsers show up as helpers
  (`com.google.Chrome.helper`), so map helper → app, and treat a browser as "maybe a call".
- Also listen to `kAudioHardwarePropertyDefaultInputDevice` changes and re-register.

## 5. Insertion (`Output.Inserter`)

TextEdit, 10 runs each:
- **AX** `kAXSelectedTextAttribute`: 0.2 ms median (max 1.3), 10/10 verified by reading
  `kAXValue` back. It works with TextEdit in the background, via the app element's focused
  element.
- **Paste fallback:** saving the pasteboard (4 types) 0.4 ms, setting it 0.8 ms. After ⌘V,
  TextEdit asked for the data in **3.8–18.8 ms (median 6.3)** and the text was visible in
  7–96 ms. Restore fidelity was 10/10 (string + RTF + custom type).
- **Safe restore:** write our text through an `NSPasteboardItemDataProvider`. The provider
  callback tells us exactly when the target read it. Restore about 50 ms after that, or after
  a 500 ms timeout if nobody asks. Add `org.nspasteboard.TransientType` / `ConcealedType`
  so clipboard managers skip it.
- **Deadlock gotcha:** polling the target over AX while it is blocked asking *us* for lazy
  pasteboard data stalls both sides until the AX messaging timeout (every paste took about
  255 ms until this was fixed). Don't make AX calls into the target while a paste is in
  flight. Set `AXUIElementSetMessagingTimeout` (0.25 s) everywhere.
- `NSPasteboard.general.accessBehavior` is `alwaysAllow` here. If a user sets yap to "ask",
  reading the pasteboard to save it will prompt, so check it and skip the save.

Probes (in our own windows):
- No text field focused (an `AXButton`): the AX set returned **success** anyway, and ⌘V made
  nobody ask for the data. So "success" is not proof: verify by reading the value back, and
  treat "no data request" as "nothing pasted" (keep the text for Paste last).
- Secure field: `AXSecureTextField` subrole detected → insert nothing.
  `IsSecureEventInputEnabled()` stayed false because the harness window was never the active
  app. Use the subrole as the main signal and secure input as a second one.
- **Focus gotcha, and an incident:** on macOS 26 an accessory process can't take focus with
  `activate()` (cooperative activation). The first probe run didn't check which process had
  focus, so it wrote "probe" via AX and ⌘V into the user's Chrome. Fixed with a pid guard.
  **The Inserter must record the target pid at key-down and refuse to insert if the focused
  pid changed.**
- ⌘V uses `kVK_ANSI_V`, which is a physical key position. Map "v" through `UCKeyTranslate`
  for non-QWERTY layouts.

```swift
public enum InsertOutcome: Sendable { case ax, paste, secureField, noTarget, focusChanged }
public struct Inserter: Sendable {
	public func insert(_ text: String, into target: FocusTarget) async -> InsertOutcome
}
```

## 6. Device policy (`Audio.DevicePolicy`)

- The list has transport for each device: built-in mic/speakers, `continuity` (iPhone mic),
  `virtual` (Teams), `displayport` (monitor). Bluetooth is `blue`/`blea` (no AirPods were
  connected).
- Pinning: set `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit` before
  starting. Without VP, pinning to the Teams virtual device worked: target running, built-in
  not running, system default unchanged (80 → 80).
- **With VP, pinning is ignored.** Capture came from the default input and the AU reported the
  output device (73). One more reason to keep dictation off VP.
- Policy: if the default input is Bluetooth, capture from the built-in mic. That keeps AirPods
  in A2DP (music quality) instead of dropping to HFP.

## Permissions yap needs

| Permission | For | When to ask |
| --- | --- | --- |
| Microphone | dictation, notes | Onboarding step 2 (`AVCaptureDevice.requestAccess`) |
| Accessibility | active event tap, AX insertion, posting ⌘V | Onboarding step 2 (`AXIsProcessTrustedWithOptions` prompt, poll for the live check) |
| System Audio Recording | notes "them" track | First notes start (the tap start triggers it); needs `NSAudioCaptureUsageDescription` |
| Input Monitoring | not needed if the active tap works with Accessibility alone | — (verify, see open issues) |

## Open issues

1. Real-key latency and Fn behaviour on external keyboards, and under secure input (manual).
2. Does an active tap work with Accessibility only, without Input Monitoring? Needs a fresh
   identity (the yap app) to test cleanly.
3. VP ducking of call audio during a real Zoom/Meet call on speakers. Decide VP vs raw +
   reference gating for notes (M3).
4. VP + non-default device (AirPods default + built-in wanted): no working pin found.
5. ~~Mid-capture device changes (`AVAudioEngineConfigurationChange`) were not probed.~~
   M1: the engine posts this notification **by itself** ~200 ms after its input unit is
   pinned, with nothing changed; rebuilding on it loops forever. `MicCapture` only acts when
   the hardware format, the pinned device (or its `IsAlive`) or the running state changed.
   On a real change mid-capture it rebuilds on the device the policy picks now and keeps the
   same stream (gap visible in host times, ~170 ms measured); after 3 restarts in one
   capture, or a failed restart, the stream finishes cleanly. Verified with a simulated
   change (engine stopped + notification); a physical unplug is still a manual check.
6. ~~`AVAudioSinkNode` for smaller chunks (waveform) was not measured.~~ M1: the sink gets
   the device's IO buffers (~10 ms); a lock-free ring hands them to a pump that yields a
   chunk every ~20 ms (cadence median 22 ms, max 30 ms). The tap stays at 100 ms.
7. ~~Whether `engine.prepare()` shows the mic indicator.~~ M1: it does not. After
   `prepare()` (and after `stop()`, which uses `pause()`), the device is not
   running somewhere and the process's `kAudioProcessPropertyIsRunningInput` is 0.
   Prepared start: mic live in 37–47 ms median.
