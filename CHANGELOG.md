# Changelog

All notable changes to BeQuiet are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.2] — 2026-11-06

Fixes BeQuiet going deaf on macOS 27.

- A pause cycle now starts when a process *joins* the set of microphone users
  and ends when the processes that started it leave. Previously any
  application holding the microphone permanently — macOS 27's speech daemon,
  or a browser with a forgotten Google Meet tab — kept the detector latched
  and no later call was ever paused.
- Processes already capturing when BeQuiet starts are a baseline and never
  start a cycle. macOS speech daemons are ignored through a built-in list that
  also reaches installations with saved settings.
- Apple Events run off the main thread, so a slow browser tab no longer
  freezes the menu bar app; a captured freeze lasted 14.3 seconds. Each tab
  gets a two second timeout and the whole browser scan an eight second budget.
- The status line names the applications holding the microphone when there is
  nothing to pause.

## [0.1.1] — 2026-09-14

- Phase transitions, microphone changes and app lifecycle log at notice level,
  which macOS persists, so `log show` can tell after the fact whether BeQuiet
  was running during a call and what it saw.
- `bequiet watch` lists output-only devices (USB speakers, HDMI) alongside the
  tracked input devices.

## [0.1.0] — 2026-09-14

First release.

- Detects microphone use through CoreAudio process state — no microphone
  permission, works for any application.
- Pauses Spotify, Apple Music and playing media in Google Chrome and Safari
  tabs; resumes only what it paused itself.
- Debounce and resume-delay presets; brief drop-outs mid-call never resume
  playback.
- Ignore list for processes that hold the microphone without a call; the
  Android Emulator is ignored by default.
- Menu bar app with Launch at Login, per-app checkboxes and browser scripting
  warnings; `bequiet` debugging CLI.

[0.1.2]: https://github.com/petrnymsa/be_quiet/releases/tag/v0.1.2
[0.1.1]: https://github.com/petrnymsa/be_quiet/releases/tag/v0.1.1
[0.1.0]: https://github.com/petrnymsa/be_quiet/releases/tag/v0.1.0
