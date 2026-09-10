import Foundation

@main
struct BeQuietCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first ?? "watch" {
        case "watch":
            await WatchCommand.run()
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
          bequiet [watch]   Print the CoreAudio microphone snapshot, then a
                            timestamped line per device/process/aggregate change.
                            Runs until interrupted (Ctrl-C).
          bequiet --help    Show this message.
        """
}
