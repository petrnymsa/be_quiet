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

- Safari, other browsers — the `MediaController` protocol keeps them easy to
  add later. (Apple Music was on this list until a colleague asked for it; see
  Media control.)
- Pausing media the user starts *during* a call.
- Distribution signing / notarization. Ad-hoc signing only.

## Package layout

```
Package.swift                 swift-tools-version 6.0, platforms: macOS 14
Sources/
  MicMonitor/                 lib   CoreAudio only, no AppKit
  MediaControl/               lib   MediaController protocol + Spotify, Chrome
  BeQuietCore/                lib   PauseStateMachine, PauseCoordinator, Settings
  BeQuietCLI/                 exe   product `bequiet` — debug CLI (watch, run, controller)
  BeQuiet/                    exe   product `BeQuietApp` — menu bar app
Tests/
  BeQuietCoreTests/           state machine, coordinator, settings store
  MediaControlTests/          AppleScript literal escaping, Chrome receipt parsing
  BeQuietAppTests/            StatusPresentation mapping
Packaging/Info.plist          bundle template (@VERSION@)
Makefile                      app / install / dist (universal zip), ad-hoc codesign
docs/DESIGN.md                this file
README.md                     install, Chrome setup, menu, debugging, limitations
```

The app product is `BeQuietApp`, not `BeQuiet`: product names that differ only
in case (`bequiet` vs `BeQuiet`) share a build directory on a case-insensitive
filesystem and overwrite each other's link inputs. The Makefile renames the
binary to `BeQuiet` inside the bundle.

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

**Truth rule:** the microphone is active iff at least one process other than
BeQuiet reports `IsRunningInput == 1`. Device-level notifications only trigger
a re-evaluation of the process snapshot and serve as a fallback if the process
list is unavailable. The CLI logs both aggregates side by side so the rule can
be validated across machines.

Phase 1 findings (validated with Google Meet in Chrome, Spotify on a USB
headset):

- The device-level false positive is real and immediate: a bidirectional
  headset reports `IsRunningSomewhere = 1` while Spotify merely plays into it.
  The process-level rule ignores it correctly.
- `kAudioProcessPropertyIsRunningInput`/`IsRunningOutput` **do not deliver
  notifications**; only `kAudioProcessPropertyIsRunning` does, and only on
  0 → 1. A process that already runs output (Teams after a notification sound,
  Chrome's audio helper while YouTube plays) and then starts input produces no
  notification, and neither does a bidirectional device that is already running
  for output. `MicMonitor` therefore re-reads the process flags on every device
  running change and additionally polls them (default 1 s) **while any
  input-capable device is running** — when none runs, no process can capture
  and the timer is idle.
- Chrome routes all audio through one `com.google.Chrome.helper` process, so
  a Meet call shows up there as `input=1`.
- `kAudioProcessPropertyBundleID` returns an empty string (not an error) for
  unbundled processes; `kAudioProcessPropertyDevices` (input scope) lists the
  device even for output-only processes, so it is not an input indicator.

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

**Ignored processes.** Some processes hold the microphone without any call:
the Android Emulator (`qemu-system-aarch64`, confirmed — it paused music on
every emulator start), virtual machines, audio tools. Settings carry
`ignoredProcesses`, a set of identity keys — the bundle ID, or the executable
name (from `proc_pidpath`) for unbundled processes — and `MicMonitor` leaves
those out of `activeProcesses`, so they never count towards activity while the
snapshot still reports them as `ignoredActiveProcesses` for the UI. The menu's
*Ignored apps* submenu lists whatever is using the microphone right now with a
checkbox per process, so the fix for a new offender is one click. The Android
Emulator is ignored by default.

Virtual *devices* (Microsoft Teams Audio, BlackHole, Loopback) turned out not
to matter: the process rule ignores devices altogether, so no device ignore
list is needed.

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
    /// Startup warm-up: compiles scripts and reads state so the first pause is
    /// fast and the Automation prompts appear at launch, not mid-call.
    func prepare() async
}
```

`PauseReceipt` is `{ controller: MediaControllerID, items: [String] }`; the
items are opaque to everyone but the controller that produced them (empty for
Spotify, `"windowID:tabID"` entries for Chrome). Keeping it a plain
`Hashable` value keeps the coordinator tests trivial.

**Spotify** — AppleScript via `NSAppleScript` (ScriptingBridge needs generated
headers, awkward under SwiftPM). Guard with `NSRunningApplication` first:
`tell application "Spotify"` would launch it. `player state` → `pause`;
resume only if the state is still `paused`.

**Apple Music** — the desktop Music.app exposes the same scripting surface as
Spotify (`player state`, `pause`, `play`; bundle ID `com.apple.Music`), so both
are one `ScriptablePlayerController` parameterised by bundle ID, display name
and controller ID. Its `player state` also knows `fast forwarding` and
`rewinding`; only `playing` is paused.

**Chrome** — the AppleScript dictionary has no `audible` property, so one
script iterates every window/tab and runs
`[...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.ended && m.readyState > 2)`
via `execute javascript`; matching tabs are paused and their IDs returned.
Requires *View → Developer → Allow JavaScript from Apple Events* in Chrome
(documented in README). Tabs with non-http URLs throw and are skipped. The
controller is parameterised by bundle ID so Brave/Arc/Edge (same dictionary)
can be enabled later; only Chrome ships enabled.

Paused elements are marked (`data-bequiet-paused`) so resume starts exactly
those and leaves media the user paused by hand in the same tab alone.

A disabled *Allow JavaScript from Apple Events* was the first real-world trap:
Chrome answers every `execute javascript` with an error and the controller
correctly reports "nothing to pause", which is indistinguishable from silence.
`ChromeController.javaScriptAccess()` probes the setting with a no-op script;
the CLI prints the result (`controller chrome`, startup warning in `run`) and
the menu bar app shows a warning item under the Chrome checkbox.

Known limitation: `play()` from an Apple Event may be blocked by Chrome's
autoplay policy on pages without prior user activation. Documented, not
worked around.

`NSAppleScript` is not thread-safe; all AppleScript runs on the main actor.
Apple Events to other apps need `NSAppleEventsUsageDescription` in Info.plist
and trigger a one-time Automation permission prompt per target app.

## Coordinator (`BeQuietCore`)

Split in two for testability:

- `PauseStateMachine` — a pure value type: `handle(event) -> [Effect]`. No
  async, no timers, no I/O. Events: `micActive`, `micInactive`,
  `debounceElapsed`, `resumeDelayElapsed`, `pauseCompleted([PauseReceipt])`,
  `settingsChanged(Settings)`. Effects: `startDebounce`/`cancelDebounce`,
  `startResumeDelay`/`cancelResumeDelay`, `pause(Set<MediaControllerID>)`,
  `resume([PauseReceipt])`. All timing and bookkeeping rules below are unit
  tests against this type.
- `@MainActor @Observable PauseCoordinator` — thin executor: feeds mic
  transitions into the machine, runs effects (timers through an injected
  `TimerScheduler`, controller calls in tasks, completion fed back as
  `pauseCompleted`), logs phase transitions, exposes `phase` / `isMicActive` /
  `heldReceipts` for the UI.

```
idle ──mic on──▶ arming            start debounce timer (default 2 s)
arming ──mic off──▶ idle           short burst, ignored
arming ──timer──▶ pausing          pauseIfPlaying() on every enabled controller
pausing ──completed──▶ paused      store the receipts (→ resumePending directly
                                   if the mic already went off meanwhile)
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
- A `pauseCompleted` arriving after the machine already left `pausing`
  (disabled mid-pause) resumes those receipts immediately, so nothing stays
  paused by accident.
- Changing debounce / resume delay does not restart a timer already running;
  new values apply to the next one.

## Settings

`UserDefaults` (suite = bundle ID), keys:

| key                      | type   | default |
|--------------------------|--------|---------|
| `enabled`                | Bool   | true    |
| `debounceSeconds`        | Double | 2       |
| `resumeDelaySeconds`     | Double | 3       |
| `controller.<id>`        | Bool   | true    |

`<id>` is the controller's raw ID: `spotify`, `chrome:com.google.Chrome`
(Chromium-family controllers carry their bundle ID so several browsers can
coexist).

Presets exposed in menu submenus: debounce 0.5 / 1 / 2 / 3 / 5 s, resume delay
1 / 2 / 3 / 5 / 10 s. No settings window.

## App shell (`BeQuiet`)

- `NSStatusItem` with an SF Symbol reflecting coordinator state: disabled,
  idle, mic active (arming), paused, resume pending. The mapping lives in a
  pure `StatusPresentation` value so it can be unit tested.
- Menu: status line (including which application holds the microphone,
  resolved from the process snapshot), Enabled toggle, controller checkboxes
  (with a warning item when Chrome refuses JavaScript from Apple Events),
  Debounce ▸ presets, Resume delay ▸ presets, Launch at Login
  (`SMAppService.mainApp`, disabled outside an `.app` bundle), Quit. Quit
  resumes anything held before terminating.
- At launch every enabled controller's `prepare()` runs, so Automation
  prompts for Spotify and Chrome show up immediately.
- Icons come from the designer's SVGs in `Packaging/Icons/`. The app icon
  (`AppIcon.svg`, 1024 squircle) is rasterised to `BeQuiet.icns` at build time
  by `Packaging/make-icons.swift` using AppKit only. The menu bar glyph
  (headphones + pause, 18 pt template) is built in code (`MenuBarIcon`) from
  the same SVG shapes, so its three states — pause bars present, faded, absent —
  need neither extra assets nor an SPM resource bundle.
- SwiftPM cannot produce `.app` bundles; the `Makefile` assembles
  `dist/BeQuiet.app` (binary, `Info.plist` with `LSUIElement`,
  `NSAppleEventsUsageDescription`, bundle ID, version) and signs it ad-hoc
  (`codesign -s -`). Targets: `make app` (current arch), `make install`
  (copy to `/Applications`), `make dist` (universal arm64 + x86_64 zip for
  GitHub Releases). Ad-hoc signatures change on every rebuild, so macOS
  re-asks the Automation permission after each rebuild — documented.
- `SMAppService` needs the bundle; README recommends copying to
  `/Applications` before enabling Launch at Login.

## CLI (`bequiet`)

Phase 1 deliverable and permanent debugging aid:

- `bequiet watch` — prints the initial device and process snapshot, then a
  timestamped line for every device/process change and for every change of
  the two aggregates (`process=1 device=0`).
- `bequiet run [--debounce s] [--resume-delay s]` — the full pipeline
  (monitor → coordinator → controllers) with a timestamped line per mic and
  phase transition. SIGINT resumes anything held before exiting.
- `bequiet controller <id>` — exercises one controller manually (state, pause,
  wait, resume); also triggers the one-time Automation permission prompt.

## Testing

- `BeQuietCoreTests` (Swift Testing): exhaustive `PauseStateMachine` tests
  (debounce, resume delay, mid-call drop-out, empty receipts, disable while
  paused, controller toggled off, late `pauseCompleted`), a few
  `PauseCoordinator` tests with a fake scheduler and recording fake
  controllers, and a `SettingsStore` round trip through a scratch
  `UserDefaults` suite.
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

## Follow-ups (post Phase 4)

### Chrome extension instead of AppleScript

*Allow JavaScript from Apple Events* cannot be switched on by an extension (it
is a browser preference outside the extension API). An extension could replace
the AppleScript path instead: `chrome.tabs.query({ audible: true })`, content
scripts with `all_frames: true` (fixes the iframe limitation), no Automation
prompt, same code for Brave/Edge/Arc, talking to BeQuiet over a localhost
WebSocket. Judged overkill for now: two artefacts to install, Web Store or a
permanent Developer-mode warning, a server and MV3 lifecycle in the app.
Revisit only if the manual setting turns out to be a real support burden or
iframe media matters. `MediaController` accommodates it without core changes.

### Distribution without a paid Apple Developer account

TestFlight is not an option: it requires the paid Developer Program, and a
macOS TestFlight build would have to be sandboxed, which makes Apple Events to
Spotify/Chrome need exception entitlements. Realistic paths:

1. **Build from source** — `git clone` + `make install`. Locally built
   binaries carry no quarantine attribute, so Gatekeeper never intervenes.
   Requires Xcode Command Line Tools. Best for developer colleagues.
2. **Ad-hoc signed `.app` via GitHub Releases** — `make dist` produces a
   universal (arm64 + x86_64) zip. Recipients hit Gatekeeper once and must use
   System Settings → Privacy & Security → *Open Anyway* (right-click → Open no
   longer works since Sequoia), or run
   `xattr -dr com.apple.quarantine /Applications/BeQuiet.app`.
3. **Homebrew tap** — repo `petrnymsa/homebrew-tap` with a cask:

   ```ruby
   cask "bequiet" do
     version "0.1.0"
     sha256 "…"
     url "https://github.com/petrnymsa/be_quiet/releases/download/v#{version}/BeQuiet-#{version}.zip"
     name "BeQuiet"
     desc "Pauses Spotify and Chrome media while the microphone is in use"
     homepage "https://github.com/petrnymsa/be_quiet"
     depends_on macos: ">= :sonoma"

     app "BeQuiet.app"

     zap trash: "~/Library/Preferences/cz.nymsa.BeQuiet.plist"
   end
   ```

   Homebrew strips the quarantine attribute on install, so the cask route
   avoids the Gatekeeper dialog entirely; the ad-hoc signature is still
   accepted because there is no notarization check for non-quarantined apps.
