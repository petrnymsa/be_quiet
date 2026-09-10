import AppKit
import BeQuietCore
import Testing

@testable import BeQuiet

@Suite("StatusPresentation")
struct StatusPresentationTests {
    @Test("disabled wins over every phase")
    func disabled() {
        for phase in [PausePhase.idle, .arming, .pausing, .paused, .resumePending] {
            let presentation = StatusPresentation(
                isEnabled: false,
                phase: phase,
                pausedControllerNames: ["Spotify"],
                micProcessNames: ["Microsoft Teams"]
            )
            #expect(presentation.symbolName == "speaker.slash")
            #expect(presentation.tooltip == "BeQuiet — disabled")
            #expect(presentation.statusText == "Disabled")
        }
    }

    @Test("idle")
    func idle() {
        let presentation = StatusPresentation(isEnabled: true, phase: .idle)
        #expect(presentation.symbolName == "speaker.wave.2")
        #expect(presentation.tooltip == "BeQuiet — idle")
        #expect(presentation.statusText == "Idle")
    }

    @Test("arming names the processes holding the microphone")
    func arming() {
        let presentation = StatusPresentation(
            isEnabled: true,
            phase: .arming,
            micProcessNames: ["Microsoft Teams", "Google Chrome"]
        )
        #expect(presentation.symbolName == "mic")
        #expect(presentation.tooltip == "BeQuiet — microphone active")
        #expect(presentation.statusText == "Microphone in use by Microsoft Teams, Google Chrome")
    }

    @Test("arming without a known process name")
    func armingWithoutNames() {
        let presentation = StatusPresentation(isEnabled: true, phase: .arming)
        #expect(presentation.statusText == "Microphone active")
    }

    @Test("pausing and paused list the controllers holding a receipt")
    func paused() {
        for phase in [PausePhase.pausing, .paused] {
            let presentation = StatusPresentation(
                isEnabled: true,
                phase: phase,
                pausedControllerNames: ["Spotify", "Google Chrome"]
            )
            #expect(presentation.symbolName == "pause.circle.fill")
            #expect(presentation.tooltip == "BeQuiet — paused: Spotify, Google Chrome")
            #expect(presentation.statusText == "Paused: Spotify, Google Chrome")
        }
    }

    @Test("paused while nothing was playing")
    func pausedWithoutReceipts() {
        let presentation = StatusPresentation(isEnabled: true, phase: .paused)
        #expect(presentation.symbolName == "pause.circle.fill")
        #expect(presentation.tooltip == "BeQuiet — nothing to pause")
        #expect(presentation.statusText == "Nothing to pause")
    }

    @Test("resume pending")
    func resumePending() {
        let presentation = StatusPresentation(
            isEnabled: true,
            phase: .resumePending,
            pausedControllerNames: ["Spotify"]
        )
        #expect(presentation.symbolName == "pause.circle")
        #expect(presentation.tooltip == "BeQuiet — resuming shortly")
        #expect(presentation.statusText == "Resuming shortly…")
    }

    @Test("every symbol the status item can show exists")
    @MainActor
    func symbolsExist() {
        var names = [StatusPresentation(isEnabled: false, phase: .idle).symbolName]
        names += [PausePhase.idle, .arming, .pausing, .paused, .resumePending].map {
            StatusPresentation(isEnabled: true, phase: $0).symbolName
        }
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is missing")
        }
    }

    @Test("preset labels drop the decimal point for whole seconds")
    func secondsLabels() {
        #expect(SecondsLabel.text(0.5) == "0.5 s")
        #expect(SecondsLabel.text(1) == "1 s")
        #expect(SecondsLabel.text(1.5) == "1.5 s")
        #expect(SecondsLabel.text(10) == "10 s")
    }
}
