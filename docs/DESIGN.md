# BeQuiet — Design

A small macOS menu bar utility that pauses media playback whenever the
microphone becomes active (a call in Teams, a Slack huddle, Google Meet in a
Chrome tab, …) and resumes it once the microphone goes idle. A DIY clone of
AutoPause. Swift, SwiftPM, no external dependencies, macOS 14+.

## Goals

- Detect microphone activity for *any* application, without microphone
  permission and without knowing the meeting apps.
- Pause Spotify (desktop) and media playing in Chrome tabs (YouTube, …).
- Resume only what BeQuiet itself paused.
- Ignore short microphone bursts (dictation, Siri, notification sounds).
- Survive brief mic drop-outs mid-call (reconnects, audio-device switches)
  without resuming playback.
- Menu bar only (`LSUIElement`), Launch at Login, configurable timings.

## Non-goals (for now)

- Apple Music, Safari, other browsers — the `MediaController` protocol keeps
  them easy to add later.
- Pausing media the user starts *during* a call.
- Distribution signing / notarization. Ad-hoc signing only.

## Package layout

```
Package.swift                 swift-tools-version 6.0, platforms: macOS 14
Sources/
  MicMonitor/                 lib   CoreAudio only, no AppKit
  MediaControl/               lib   MediaController protocol + Spotify, Chrome
  BeQuietCore/                lib   PauseCoordinator state machine, Settings
  BeQuietCLI/                 exe   `bequiet` — Phase 1 spike, later a debug tool
  BeQuiet/                    exe   menu bar app (NSStatusItem, SMAppService)
Tests/
  BeQuietCoreTests/           coordinator tests with fake clock / mic / controllers
Makefile                      release build → BeQuiet.app bundle → ad-hoc codesign
docs/DESIGN.md                this file
README.md                     build, install, Chrome setup, known limitations
```

Swift 6 language mode with strict concurrency. Bundle identifier
`cz.nymsa.BeQuiet`; `os.Logger` subsystem `cz.nymsa.BeQuiet` with categories
`mic`, `coordinator`, `spotify`, `chrome`, `app`.

## Microphone detection (`MicMonitor`)

Two CoreAudio signals are observed, neither requires microphone permission
(no audio is captured, only device/process state):

1. **Device level** — `kAudioDevicePropertyDeviceIsRunningSomewhere` on every
   device that has at least one input stream. Reliable notifications, but the
   property is per device, not per scope: a bidirectional device (AirPods,
   USB headset) reports `1` while it merely plays audio. On its own this
   produces false positives.
2. **Process level** (macOS 14+) — `kAudioHardwarePropertyProcessObjectList`
   on the system object, and per process object `kAudioProcessPropertyPID`,
   `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningInput`,
   `kAudioProcessPropertyDevices` (input scope). Distinguishes input from
   output regardless of device topology and tells *which* process holds the
   microphone.

**Truth rule (initial):** the microphone is active iff at least one process
other than BeQuiet reports `IsRunningInput == 1`. Device-level notifications
only trigger a re-evaluation of the process snapshot and serve as a fallback
if the process list is unavailable. Phase 1 logs both aggregates side by side
so the rule can be validated across several machines and adjusted.

Other requirements:

- Listener on `kAudioHardwarePropertyDevices` for hot-plug; per-device
  listeners are added/removed as devices appear/disappear.
- Listener on `kAudioHardwarePropertyProcessObjectList`; per-process listeners
  on `IsRunningInput`.
- All CoreAudio work happens on one private serial `DispatchQueue`, which is
  also the queue passed to `AudioObjectAddPropertyListenerBlock`. No shared
  mutable state outside that queue.
- Public API: `MicMonitor.events: AsyncStream<MicEvent>` plus a `snapshot()`
  describing devices and processes. `MicEvent` carries
  `micActive(Bool, reason: String)` transitions and the raw device/process
  changes for logging.

Open risk: virtual devices (Microsoft Teams Audio, BlackHole, Loopback) may
report running permanently. If Phase 1 confirms this, add a per-device ignore
list (by device UID) to settings.

## Media control (`MediaControl`)

```swift
public protocol MediaController: Sendable {
    var id: MediaControllerID { get }          // .spotify, .chrome(bundleID)
    var displayName: String { get }
    /// Pauses whatever is playing. Returns nil when nothing was playing or the
    /// app is not running. Never launches the target application.
    func pauseIfPlaying() async -> PauseReceipt?
    /// Resumes only the items described by the receipt, and only if they are
    /// still paused. Missing tabs / quit apps are ignored.
    func resume(_ receipt: PauseReceipt) async
}
```

`PauseReceipt` is an opaque, controller-specific value: a marker for Spotify,
a list of `(windowID, tabID)` for Chrome.

**Spotify** — AppleScript via `NSAppleScript` (ScriptingBridge needs generated
headers, awkward under SwiftPM). Guard with `NSRunningApplication` first:
`tell application "Spotify"` would launch it. `player state` → `pause`;
resume only if the state is still `paused`.

**Chrome** — the AppleScript dictionary has no `audible` property, so one
script iterates every window/tab and runs
`[...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.ended && m.readyState > 2)`
via `execute javascript`; matching tabs are paused and their IDs returned.
Requires *View → Developer → Allow JavaScript from Apple Events* in Chrome
(documented in README). Tabs with non-http URLs throw and are skipped. The
controller is parameterised by bundle ID so Brave/Arc/Edge (same dictionary)
can be enabled later; only Chrome ships enabled.

Known limitation: `play()` from an Apple Event may be blocked by Chrome's
autoplay policy on pages without prior user activation. Documented, not
worked around.

`NSAppleScript` is not thread-safe; all AppleScript runs on the main actor.
Apple Events to other apps need `NSAppleEventsUsageDescription` in Info.plist
and trigger a one-time Automation permission prompt per target app.

## Coordinator (`BeQuietCore`)

`@MainActor final class PauseCoordinator` consumes `MicMonitor.events`,
applies timing, drives the controllers, and exposes `@Observable` state for
the UI. Time is injected (`Clock`) so the state machine is unit-testable.

```
idle ──mic on──▶ arming            start debounce timer (default 2 s)
arming ──mic off──▶ idle           short burst, ignored
arming ──timer──▶ paused           pauseIfPlaying() on every enabled controller,
                                   store the receipts
paused ──mic off──▶ resumePending  start resume timer (default 3 s)
resumePending ──mic on──▶ paused   reconnect / device switch: cancel timer, keep receipts
resumePending ──timer──▶ idle      resume(receipt) for each stored receipt, clear them
```

Rules:

- Nothing is scanned or paused while in `paused`; media the user starts during
  a call is never touched.
- Controllers that returned `nil` from `pauseIfPlaying()` are not resumed
  (Spotify already paused before the call stays paused).
- Disabling BeQuiet or quitting while in `paused`/`resumePending` resumes the
  stored receipts immediately.
- A controller toggled off while it holds a receipt is resumed at that moment.

## Settings

`UserDefaults` (suite = bundle ID), keys:

| key                      | type   | default |
|--------------------------|--------|---------|
| `enabled`                | Bool   | true    |
| `debounceSeconds`        | Double | 2       |
| `resumeDelaySeconds`     | Double | 3       |
| `controller.spotify`     | Bool   | true    |
| `controller.chrome`      | Bool   | true    |

Presets exposed in menu submenus: debounce 0.5 / 1 / 2 / 3 / 5 s, resume delay
1 / 2 / 3 / 5 / 10 s. No settings window.

## App shell (`BeQuiet`)

- `NSStatusItem` with an SF Symbol reflecting coordinator state: idle,
  mic active (arming), paused.
- Menu: Enabled toggle, controller checkboxes, Debounce ▸ presets,
  Resume delay ▸ presets, Launch at Login (`SMAppService.mainApp`), Quit.
- SwiftPM cannot produce `.app` bundles; the `Makefile` assembles
  `dist/BeQuiet.app` (binary, `Info.plist` with `LSUIElement`,
  `NSAppleEventsUsageDescription`, bundle ID, version) and signs it ad-hoc
  (`codesign -s -`). Ad-hoc signatures change on every rebuild, so macOS
  re-asks the Automation permission after each rebuild — documented.
- `SMAppService` needs the bundle; README recommends copying to
  `/Applications` before enabling Launch at Login.

## CLI (`bequiet`)

Phase 1 deliverable and permanent debugging aid:

- `bequiet watch` — prints the initial device and process snapshot, then a
  timestamped line for every device/process change and for every change of
  the two aggregates (`process=1 device=0`).
- Later: `bequiet pause` / `bequiet resume` to exercise controllers manually.

## Testing

- `BeQuietCoreTests`: state machine with a fake clock, a scripted mic event
  source, and recording fake controllers. Covers debounce, resume delay,
  mid-call drop-out, nil receipts, disable-while-paused.
- CoreAudio and AppleScript layers are verified manually per phase (real
  Teams / Slack / Meet / AirPods); the CLI exists for that.

## Phases

1. **CLI spike** — `MicMonitor` + `bequiet watch`. Validate detection on real
   setups; decide the final truth rule and whether an ignore list is needed.
2. **Spotify** — `MediaControl` protocol, `SpotifyController`,
   `PauseCoordinator` with tests, CLI wired end to end.
3. **Chrome** — `ChromeController`, README section on the Chrome setting.
4. **Menu bar app** — `BeQuiet` target, Makefile bundle + signing, Launch at
   Login, README.

Each phase ends with a manual test by the user before the next one starts.
