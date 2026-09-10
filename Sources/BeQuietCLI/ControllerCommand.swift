import Darwin
import Foundation
import MediaControl

/// Exercises one controller by hand: this is what triggers the one-time
/// Automation permission prompt for the terminal application.
enum ControllerCommand {
    @MainActor
    private static let controllers: [String: any InspectableController] = [
        "spotify": SpotifyController(),
        "chrome": ChromeController(),
    ]

    @MainActor
    private static var knownNames: String {
        controllers.keys.sorted().joined(separator: "|")
    }

    @MainActor
    static func run(arguments: [String]) async {
        guard arguments.count == 1 else {
            Output.error("usage: bequiet controller <\(knownNames)>")
            exit(2)
        }
        guard let controller = controllers[arguments[0]] else {
            Output.error("unknown controller: \(arguments[0]) (known: \(knownNames))")
            exit(2)
        }
        await check(controller)
    }

    @MainActor
    private static func check(_ controller: any InspectableController) async {
        Output.line("controller:  \(controller.displayName) (\(controller.id))")
        Output.line("running:     \(controller.isRunning ? "yes" : "no")")
        printState(of: controller)

        guard let receipt = await controller.pauseIfPlaying() else {
            Output.line("pause:       nothing to pause")
            return
        }
        Output.line("pause:       receipt \(receipt.controller) items=\(receipt.items)")
        printState(of: controller)

        Output.line("waiting 3 s before resuming")
        try? await Task.sleep(for: .seconds(3))

        await controller.resume(receipt)
        Output.line("resume:      done")
        printState(of: controller)
    }

    @MainActor
    private static func printState(of controller: any InspectableController) {
        guard let state = controller.stateDescription else { return }
        Output.line("state:       \(state)")
    }
}

/// `isRunning` and Spotify's player state are worth printing but are no business
/// of `MediaController`; this keeps the command generic without widening the
/// protocol every controller has to satisfy.
private protocol InspectableController: MediaController {
    @MainActor var isRunning: Bool { get }
    /// `nil` for controllers with no single state to report, such as a browser
    /// with any number of tabs.
    @MainActor var stateDescription: String? { get }
}

extension SpotifyController: InspectableController {
    var stateDescription: String? { playerState()?.description ?? "unknown" }
}

extension ChromeController: InspectableController {
    var stateDescription: String? { nil }
}
