import AppKit
import MicMonitor

/// The processes currently holding the microphone, kept up to date from the
/// monitor's events so the menu can name them when it opens.
@MainActor
final class MicActivity {
    private(set) var activeProcesses: [AudioProcessInfo] = []

    func update(_ processes: [AudioProcessInfo]) {
        activeProcesses = processes
    }

    /// Localised application names where macOS knows the process, its bundle ID
    /// otherwise, and the bare pid for daemons and command line tools.
    var processNames: [String] {
        activeProcesses.map { process in
            NSRunningApplication(processIdentifier: process.pid)?.localizedName
                ?? process.bundleID
                ?? "pid \(process.pid)"
        }
    }
}
