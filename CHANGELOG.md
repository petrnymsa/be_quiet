# Changelog

All notable changes to BeQuiet are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[0.1.1]: https://github.com/petrnymsa/be_quiet/releases/tag/v0.1.1
[0.1.0]: https://github.com/petrnymsa/be_quiet/releases/tag/v0.1.0
