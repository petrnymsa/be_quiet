import Darwin
import Foundation
import MediaControl

/// Exercises one controller by hand: this is what triggers the one-time
/// Automation permission prompt for the terminal application.
enum ControllerCommand {
    @MainActor
    static func run(arguments: [String]) async {
        guard arguments.count == 1 else {
            Output.error("usage: bequiet controller spotify")
            exit(2)
        }

        switch arguments[0] {
        case "spotify":
            await checkSpotify()
        case let unknown:
            Output.error("unknown controller: \(unknown) (known: spotify)")
            exit(2)
        }
    }

    @MainActor
    private static func checkSpotify() async {
        let controller = SpotifyController()
        Output.line("controller:  \(controller.displayName) (\(controller.id))")
        Output.line("running:     \(controller.isRunning ? "yes" : "no")")
        Output.line("state:       \(state(of: controller))")

        guard let receipt = await controller.pauseIfPlaying() else {
            Output.line("pause:       nothing to pause")
            return
        }
        Output.line("pause:       receipt \(receipt.controller) items=\(receipt.items)")
        Output.line("state:       \(state(of: controller))")

        Output.line("waiting 3 s before resuming")
        try? await Task.sleep(for: .seconds(3))

        await controller.resume(receipt)
        Output.line("resume:      done")
        Output.line("state:       \(state(of: controller))")
    }

    @MainActor
    private static func state(of controller: SpotifyController) -> String {
        controller.playerState()?.description ?? "unknown"
    }
}
