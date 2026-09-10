import BeQuietCore
import Darwin
import Foundation
import MediaControl
import MicMonitor

enum RunCommand {
    @MainActor
    static func run(arguments: [String]) async {
        guard let overrides = Overrides(arguments: arguments) else { exit(2) }

        var settings = SettingsStore().load()
        if let seconds = overrides.debounceSeconds { settings.debounceSeconds = seconds }
        if let seconds = overrides.resumeDelaySeconds { settings.resumeDelaySeconds = seconds }

        let monitor = MicMonitor()
        let events = monitor.start()
        let interrupts = Interrupts.install { monitor.stop() }

        let log = TransitionLog()
        let coordinator = PauseCoordinator(
            controllers: [SpotifyController()],
            settings: settings,
            onTransition: { from, to in log.record(from, to) }
        )
        log.coordinator = coordinator

        Output.line("bequiet run — pauses media while the microphone is active (Ctrl-C to stop)")
        Output.line(
            "controllers: \(settings.enabledControllers.map(\.rawValue).sorted().joined(separator: ", "))  "
                + "debounce: \(settings.debounceSeconds)s  resume delay: \(settings.resumeDelaySeconds)s  "
                + "enabled: \(flag(settings.isEnabled))"
        )
        let initial = monitor.snapshot()
        Output.line(initial.aggregatesLine)
        Output.line()

        // `start()` reports transitions only, so the current state is fed in by hand.
        coordinator.micActivityChanged(isActive: initial.micActive)

        for await event in events {
            guard case let .micActivityChanged(isActive, _, snapshot) = event else { continue }
            let status = isActive ? "ACTIVE" : "INACTIVE"
            Output.event("MIC", "\(status.padded(to: 8)) \(snapshot.activeProcessNames)")
            coordinator.micActivityChanged(isActive: isActive)
        }

        await coordinator.shutdown()
        interrupts.forEach { $0.cancel() }
        Output.line()
        Output.line("run stopped.")
        exit(0)
    }
}

private struct Overrides {
    var debounceSeconds: TimeInterval?
    var resumeDelaySeconds: TimeInterval?

    init?(arguments: [String]) {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            switch option {
            case "--debounce", "--resume-delay":
                guard index + 1 < arguments.endIndex,
                      let seconds = TimeInterval(arguments[index + 1]),
                      seconds >= 0
                else {
                    Output.error("\(option) needs a non-negative number of seconds")
                    return nil
                }
                if option == "--debounce" {
                    debounceSeconds = seconds
                } else {
                    resumeDelaySeconds = seconds
                }
                index += 2

            default:
                Output.error("unknown option: \(option)")
                return nil
            }
        }
    }
}

/// Prints one line per coordinator phase transition. The receipts are gone from
/// the coordinator by the time the resume happens, so the last ones seen are
/// remembered for that line.
@MainActor
private final class TransitionLog {
    weak var coordinator: PauseCoordinator?

    private var lastReceipts: [PauseReceipt] = []

    func record(_ from: PausePhase, _ to: PausePhase) {
        let held = coordinator?.heldReceipts ?? []
        if !held.isEmpty { lastReceipts = held }

        var suffix = ""
        switch (from, to) {
        case (.pausing, _) where !held.isEmpty:
            suffix = "   receipts: \(names(held))"
        case (_, .idle) where !lastReceipts.isEmpty:
            suffix = "   resumed: \(names(lastReceipts))"
            lastReceipts = []
        default:
            break
        }
        Output.event("STATE", "\(from) → \(to)\(suffix)")
    }

    private func names(_ receipts: [PauseReceipt]) -> String {
        receipts.map(\.controller.rawValue).joined(separator: ", ")
    }
}
