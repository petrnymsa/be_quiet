# BeQuiet

A small macOS menu bar utility that pauses media playback whenever the
microphone becomes active — a call in Teams, a Slack huddle, Google Meet in a
browser tab — and resumes it once the microphone goes idle again. macOS 14+,
Swift, no external dependencies.

## What it does

- Pauses Spotify and playing media in Google Chrome tabs when a call starts.
- Resumes exactly what it paused itself, once the microphone has been idle for
  a few seconds.
- Ignores short microphone bursts (dictation, Siri) through a debounce delay.
- Survives brief drop-outs mid-call (reconnects, audio device switches) without
  resuming playback.
- Leaves media the user starts *during* a call alone: while the microphone is
  active nothing is scanned or paused.
- Lives in the menu bar only — no Dock icon, no windows, no settings sheet.

## How detection works

BeQuiet asks CoreAudio which processes are currently *running input*
(`kAudioHardwarePropertyProcessObjectList`, macOS 14+). The microphone counts
as active as soon as any process other than BeQuiet reports input.

- No microphone permission is needed and no audio is ever captured — only
  device and process state is read.
- It works for *any* application, without knowing the meeting apps: Teams,
  Slack, Zoom, FaceTime, a Meet tab in Chrome all look the same from here.
- Device-level state (`kAudioDevicePropertyDeviceIsRunningSomewhere`) is used
  only to re-evaluate the process list, because a bidirectional device
  (AirPods, USB headset) reports as running while it merely plays audio. It
  serves as a fallback if the process list cannot be read at all.

## Requirements

- macOS 14 (Sonoma) or newer.
- Xcode Command Line Tools to build (`xcode-select --install`).

## Install

```sh
git clone https://github.com/petrnymsa/be_quiet.git
cd be_quiet
make install
open /Applications/BeQuiet.app
```

`make install` builds a release binary, assembles `dist/BeQuiet.app`, signs it
ad-hoc and copies it to `/Applications`. BeQuiet then sits in the menu bar; it
has no Dock icon and no main window.

On the first launch macOS asks twice for permission to control Spotify and
Google Chrome. BeQuiet warms both controllers up at startup precisely so the
prompts appear right away instead of in the middle of a call. Both have to be
allowed; the answers can be changed later under System Settings → Privacy &
Security → Automation.

The signature is ad-hoc (there is no paid Developer account), and its identity
changes with every rebuild, so macOS treats each rebuild as a new application
and asks again. To clean up the accumulated answers:

```sh
tccutil reset AppleEvents cz.nymsa.BeQuiet
```

## Chrome setup

Chrome exposes no "is this tab playing audio" property to AppleScript, so
BeQuiet asks each tab through `execute javascript`. That requires one setting
inside Chrome:

- **View → Developer → Allow JavaScript from Apple Events**

The menu item is a per-profile setting, so it has to be switched on in every
Chrome profile whose tabs should be paused. Without it Chrome refuses every
script with *"Executing JavaScript through AppleScript is turned off"*; BeQuiet
shows a warning under the *Pause Google Chrome* menu item and pauses nothing.

The first time BeQuiet sends an Apple Event to Chrome, macOS shows the one-time
Automation prompt described above. When the CLI is used from a terminal, the
prompt names the terminal application rather than BeQuiet, because that is the
process sending the event.

## Menu reference

| item | meaning |
|---|---|
| first line | current state: `Idle`, `Microphone in use by Microsoft Teams`, `Paused: Spotify, Google Chrome`, `Resuming shortly…`, `Disabled` |
| `Enabled` | master switch; switching it off resumes anything BeQuiet holds |
| `Pause Spotify` | whether Spotify is paused during calls |
| `Pause Google Chrome` | whether playing Chrome tabs are paused during calls |
| `⚠︎ Allow JavaScript from Apple Events is off …` | shown while Chrome refuses scripting; see *Chrome setup* |
| `Debounce ▸` | how long the microphone must stay active before media is paused (0.5–5 s) |
| `Resume delay ▸` | how long the microphone must stay idle before media is resumed (1–10 s) |
| `Launch at Login` | register BeQuiet as a login item; see below |
| `Quit BeQuiet` | resumes anything BeQuiet paused, then exits |

The status item icon follows the same state: a speaker when idle, a crossed-out
speaker when disabled, a microphone while the debounce runs, and a pause symbol
while media is paused.

## Launch at Login

`Launch at Login` uses `SMAppService`, which registers the *application
bundle*. It is therefore only available when BeQuiet runs from
`/Applications/BeQuiet.app` — the item is disabled for a binary started with
`swift run`.

macOS may put the new login item on hold; the menu item then reads
*Launch at Login (approve in System Settings)* and opens
System Settings → General → Login Items, where BeQuiet has to be switched on.

## Advanced settings

Everything the menu offers is stored in `UserDefaults` under the bundle ID, and
values outside the menu presets can be set by hand:

```sh
defaults write cz.nymsa.BeQuiet debounceSeconds -float 1.5
```

| key | type | default |
|---|---|---|
| `enabled` | Bool | `true` |
| `debounceSeconds` | Double | `2` |
| `resumeDelaySeconds` | Double | `3` |
| `controller.spotify` | Bool | `true` |
| `controller.chrome:com.google.Chrome` | Bool | `true` |

BeQuiet reads the settings at startup, so it has to be restarted afterwards. A
value that matches no preset shows up in the submenu as `Custom: 1.5 s`.

## Debugging

The `bequiet` CLI is the debugging aid for the same pipeline:

```sh
swift run bequiet watch                 # microphone snapshot + every change
swift run bequiet run                   # the full pipeline with a log line per transition
swift run bequiet controller spotify    # pause and resume one controller by hand
swift run bequiet controller chrome
```

Both the app and the CLI log to the unified log:

```sh
log stream --predicate 'subsystem == "cz.nymsa.BeQuiet"' --level debug
```

Categories are `mic`, `coordinator`, `spotify`, `chrome` and `app`.

## Known limitations

- **Media inside cross-origin iframes is invisible.** `execute javascript` runs
  in the top document only, so embedded players (a YouTube or Spotify embed on
  a third-party page, most ad players) are neither found nor paused.
- **Resuming can be refused by the autoplay policy.** `play()` from an Apple
  Event has no user activation behind it, so Chrome may reject it on pages the
  user has not interacted with. Nothing is broken, the tab simply stays paused.
- **Only Chrome is enabled.** Brave, Arc, Microsoft Edge and Chromium share
  Chrome's scripting dictionary, and `ChromeController(bundleID:)` accepts any
  of their bundle IDs, but there is no user interface for adding them yet.
- **Media started during a call is left alone**, by design: while the
  microphone is active nothing is scanned or paused.
- **Gatekeeper stops a downloaded build.** The zip from `make dist` carries no
  notarization, so a downloaded copy has to be allowed under System Settings →
  Privacy & Security → *Open Anyway*, or unquarantined by hand:
  `xattr -dr com.apple.quarantine /Applications/BeQuiet.app`. A locally built
  copy is never quarantined and needs neither.

## Development

```sh
swift build          # everything, debug
swift test           # coordinator, settings, Chrome scripting, status presentation
make app             # dist/BeQuiet.app, current architecture, ad-hoc signed
make install         # the same, copied to /Applications
make dist            # universal (arm64 + x86_64) dist/BeQuiet-<version>.zip
make clean
```

```
Sources/
  MicMonitor/     CoreAudio microphone detection, no AppKit
  MediaControl/   MediaController protocol, Spotify and Chromium controllers
  BeQuietCore/    PauseStateMachine, PauseCoordinator, Settings
  BeQuietCLI/     `bequiet` — the debugging CLI
  BeQuiet/        the menu bar app (status item, menu, launch at login)
Tests/            state machine, coordinator, settings, scripting, presentation
Packaging/        Info.plist template for the app bundle
Makefile          release build → BeQuiet.app → ad-hoc signature
docs/DESIGN.md    architecture, detection findings, decisions
```

The app is built as the `BeQuietApp` product and installed as `BeQuiet.app`:
two executable products whose names differ only in case (`BeQuiet` and
`bequiet`) cannot coexist in the build directory on a case-insensitive
filesystem.
