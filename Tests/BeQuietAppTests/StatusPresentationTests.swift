import AppKit
import BeQuietCore
import Testing

@testable import BeQuiet

@Suite("StatusPresentation")
struct StatusPresentationTests {
    @Test("disabled wins over every phase and dims the listening glyph")
    func disabled() {
        for phase in [PausePhase.idle, .arming, .pausing, .paused, .resumePending] {
            let presentation = StatusPresentation(
                isEnabled: false,
                phase: phase,
                pausedControllerNames: ["Spotify"],
                micProcessNames: ["Microsoft Teams"]
            )
            #expect(presentation.icon == .listening)
            #expect(presentation.isDimmed)
            #expect(presentation.tooltip == "BeQuiet — disabled")
            #expect(presentation.statusText == "Disabled")
        }
    }

    @Test("idle")
    func idle() {
        let presentation = StatusPresentation(isEnabled: true, phase: .idle)
        #expect(presentation.icon == .listening)
        #expect(!presentation.isDimmed)
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
        #expect(presentation.icon == .armed)
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
            #expect(presentation.icon == .paused)
            #expect(presentation.tooltip == "BeQuiet — paused: Spotify, Google Chrome")
            #expect(presentation.statusText == "Paused: Spotify, Google Chrome")
        }
    }

    @Test("paused while nothing was playing")
    func pausedWithoutReceipts() {
        let presentation = StatusPresentation(isEnabled: true, phase: .paused)
        #expect(presentation.icon == .paused)
        #expect(presentation.tooltip == "BeQuiet — nothing to pause")
        #expect(presentation.statusText == "Nothing to pause")
    }

    @Test("resume pending shows the armed glyph")
    func resumePending() {
        let presentation = StatusPresentation(
            isEnabled: true,
            phase: .resumePending,
            pausedControllerNames: ["Spotify"]
        )
        #expect(presentation.icon == .armed)
        #expect(presentation.tooltip == "BeQuiet — resuming shortly")
        #expect(presentation.statusText == "Resuming shortly…")
    }

    @Test("every glyph renders as an 18 pt template image")
    @MainActor
    func iconsRender() {
        for icon in MenuBarIcon.allCases {
            let image = icon.image
            #expect(image.isTemplate, "\(icon) is not a template image")
            #expect(image.size == NSSize(width: 18, height: 18), "\(icon) has size \(image.size)")
            #expect(!image.representations.isEmpty, "\(icon) has no representation")
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
