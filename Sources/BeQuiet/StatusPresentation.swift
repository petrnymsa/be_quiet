import BeQuietCore
import Foundation

/// Everything the status item and the first menu line show, derived from the
/// coordinator state alone. A value type with no AppKit in sight, so the whole
/// mapping is unit tested.
struct StatusPresentation: Hashable {
    let symbolName: String
    let tooltip: String
    let statusText: String

    /// - Parameters:
    ///   - pausedControllerNames: display names of the controllers currently
    ///     holding a receipt.
    ///   - micProcessNames: display names of the processes holding the
    ///     microphone, already resolved to something human readable.
    init(
        isEnabled: Bool,
        phase: PausePhase,
        pausedControllerNames: [String] = [],
        micProcessNames: [String] = []
    ) {
        guard isEnabled else {
            symbolName = "speaker.slash"
            tooltip = "BeQuiet — disabled"
            statusText = "Disabled"
            return
        }

        switch phase {
        case .idle:
            symbolName = "speaker.wave.2"
            tooltip = "BeQuiet — idle"
            statusText = "Idle"

        case .arming:
            symbolName = "mic"
            tooltip = "BeQuiet — microphone active"
            statusText = micProcessNames.isEmpty
                ? "Microphone active"
                : "Microphone in use by \(micProcessNames.list)"

        case .pausing, .paused:
            symbolName = "pause.circle.fill"
            // Nothing was playing when the call started: the phase is still
            // `paused` but there is nothing to name.
            if pausedControllerNames.isEmpty {
                tooltip = "BeQuiet — nothing to pause"
                statusText = "Nothing to pause"
            } else {
                tooltip = "BeQuiet — paused: \(pausedControllerNames.list)"
                statusText = "Paused: \(pausedControllerNames.list)"
            }

        case .resumePending:
            symbolName = "pause.circle"
            tooltip = "BeQuiet — resuming shortly"
            statusText = "Resuming shortly…"
        }
    }
}

/// Menu labels for the timing presets: whole seconds without a decimal point,
/// fractions with one.
enum SecondsLabel {
    static func text(_ seconds: TimeInterval) -> String {
        String(format: "%g s", seconds)
    }
}

private extension [String] {
    var list: String { joined(separator: ", ") }
}
