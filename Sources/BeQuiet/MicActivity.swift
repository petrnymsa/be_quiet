import AppKit
import MicMonitor

/// The processes currently holding the microphone, kept up to date from the
/// monitor's events so the menu can name them when it opens.
@MainActor
final class MicActivity {
    /// One row of the *Ignored apps* submenu: a process that is holding the
    /// microphone right now.
    struct MicrophoneUser: Hashable {
        /// `nil` for a process with neither a bundle ID nor a readable
        /// executable path — nothing that could be persisted in the ignore list.
        let identityKey: String?
        let displayName: String
        let isIgnored: Bool
    }

    private(set) var activeProcesses: [AudioProcessInfo] = []
    private(set) var ignoredActiveProcesses: [AudioProcessInfo] = []

    func update(_ snapshot: MicSnapshot) {
        activeProcesses = snapshot.activeProcesses
        ignoredActiveProcesses = snapshot.ignoredActiveProcesses
    }

    var processNames: [String] { activeProcesses.map(displayName) }

    var ignoredProcessNames: [String] { ignoredActiveProcesses.map(displayName) }

    /// Everything running input, ignored or not, one row per identity and
    /// sorted the way the menu shows them.
    var microphoneUsers: [MicrophoneUser] {
        let users = activeProcesses.map { user($0, isIgnored: false) }
            + ignoredActiveProcesses.map { user($0, isIgnored: true) }

        // One application can hold several audio process objects; the user
        // ignores the identity, so the menu shows it once.
        var seen: Set<String> = []
        return users
            .filter { user in
                guard let key = user.identityKey else { return true }
                return seen.insert(key).inserted
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func user(_ process: AudioProcessInfo, isIgnored: Bool) -> MicrophoneUser {
        MicrophoneUser(
            identityKey: process.identityKey,
            displayName: displayName(process),
            isIgnored: isIgnored
        )
    }

    /// Localised application names where macOS knows the process, the
    /// executable name for daemons and command line tools, and the bare pid
    /// when even the executable path is unreadable.
    private func displayName(_ process: AudioProcessInfo) -> String {
        NSRunningApplication(processIdentifier: process.pid)?.localizedName
            ?? process.executableName
            ?? process.bundleID
            ?? "pid \(process.pid)"
    }
}
