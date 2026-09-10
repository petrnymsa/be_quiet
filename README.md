# BeQuiet

A small macOS utility that pauses media playback whenever the microphone
becomes active — a call in Teams, a Slack huddle, Google Meet in a browser tab —
and resumes it once the microphone goes idle again. Microphone activity is
detected through CoreAudio process state, so BeQuiet needs no microphone
permission and no knowledge of the meeting applications. Short bursts
(dictation, Siri) are ignored, brief drop-outs mid-call do not resume playback,
and only what BeQuiet paused itself is ever started again. macOS 14+, Swift,
no external dependencies. The menu bar app is still to come; for now everything
runs through the `bequiet` CLI (`bequiet run`, `bequiet watch`,
`bequiet controller <spotify|chrome>`).

## Chrome setup

Chrome exposes no "is this tab playing audio" property to AppleScript, so
BeQuiet asks each tab through `execute javascript`. That requires one setting
inside Chrome:

- **View → Developer → Allow JavaScript from Apple Events**

The menu item is a per-profile setting, so it has to be switched on in every
Chrome profile whose tabs should be paused. Without it Chrome refuses every
script with *"Executing JavaScript through AppleScript is turned off"*; BeQuiet
logs that message together with this hint and pauses nothing.

The first time BeQuiet sends an Apple Event to Chrome, macOS shows a one-time
Automation prompt (*"… wants to control Google Chrome"*). It has to be allowed;
it can be revoked or restored later under System Settings → Privacy & Security →
Automation. When the CLI is used from a terminal, the prompt names the terminal
application rather than BeQuiet, because that is the process sending the event.

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
