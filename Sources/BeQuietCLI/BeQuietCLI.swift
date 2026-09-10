import Foundation

@main
struct BeQuietCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first ?? "watch" {
        case "watch":
            await WatchCommand.run()
        case "run":
            await RunCommand.run(arguments: Array(arguments.dropFirst()))
        case "controller":
            await ControllerCommand.run(arguments: Array(arguments.dropFirst()))
        case "--help", "-h", "help":
            Output.line(usage)
        case let unknown:
            Output.error("unknown command: \(unknown)")
            Output.error(usage)
            exit(2)
        }
    }

    private static let usage = """
        bequiet — BeQuiet debugging CLI

        Usage:
          bequiet [watch]           Print the CoreAudio microphone snapshot, then a
                                    timestamped line per device/process/aggregate
                                    change. Runs until interrupted (Ctrl-C).

          bequiet run [options]     Pause the enabled media controllers while the
                                    microphone is active and resume them afterwards.
                                    Prints a line per microphone and state change.
                                    Ctrl-C resumes anything still paused.
            --debounce <s>          Microphone activity ignored below this (default
                                    from settings, 2 s).
            --resume-delay <s>      Wait after the microphone goes idle before
                                    resuming (default from settings, 3 s).

          bequiet controller <spotify|chrome>
                                    Check one controller by hand: print its state,
                                    pause it, wait 3 s, resume it. Triggers the
                                    Automation permission prompt. `chrome` also
                                    needs View → Developer → Allow JavaScript
                                    from Apple Events in Chrome.

          bequiet --help            Show this message.
        """
}
