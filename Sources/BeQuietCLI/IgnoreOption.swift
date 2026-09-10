import Foundation

/// `--ignore <name>`, repeatable: bundle IDs or executable names added to the
/// ignore list from the settings for this run only, so a suspect process can be
/// tried out without writing to `defaults`.
enum IgnoreOption {
    /// Removes every `--ignore <name>` pair from `arguments` and returns the
    /// names, or `nil` when the option is missing its value.
    static func extract(from arguments: inout [String]) -> Set<String>? {
        var names: Set<String> = []
        var remaining: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            guard arguments[index] == "--ignore" else {
                remaining.append(arguments[index])
                index += 1
                continue
            }
            guard index + 1 < arguments.endIndex, !arguments[index + 1].isEmpty else {
                Output.error("--ignore needs a bundle ID or executable name")
                return nil
            }
            names.insert(arguments[index + 1])
            index += 2
        }
        arguments = remaining
        return names
    }

    static func headerLine(_ processes: Set<String>) -> String? {
        guard !processes.isEmpty else { return nil }
        return "ignoring: \(processes.sorted().joined(separator: ", "))"
    }
}
