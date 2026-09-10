import AppKit
import Foundation
import os

let playerLogger = Logger(subsystem: "cz.nymsa.BeQuiet", category: "player")

public enum PlayerState: String, Sendable, CustomStringConvertible {
    case playing
    case paused
    case stopped
    // Apple Music only.
    case fastForwarding = "fast forwarding"
    case rewinding

    public var description: String { rawValue }
}

/// Desktop players that script the same way — `player state`, `pause`, `play`.
/// Spotify and Apple Music differ only in their bundle ID.
public struct ScriptablePlayerController: MediaController {
    public static let spotify = ScriptablePlayerController(
        id: .spotify,
        displayName: "Spotify",
        bundleID: "com.spotify.client"
    )
    public static let appleMusic = ScriptablePlayerController(
        id: .appleMusic,
        displayName: "Apple Music",
        bundleID: "com.apple.Music"
    )

    public let id: MediaControllerID
    public let displayName: String
    private let bundleID: String

    public init(id: MediaControllerID, displayName: String, bundleID: String) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
    }

    /// Checked before every script: `tell application` launches its target, and
    /// BeQuiet must never start a player.
    @MainActor public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// `nil` when the player is not running or the state could not be read.
    @MainActor public func playerState() -> PlayerState? {
        guard isRunning, let result = run(.playerState) else { return nil }
        return result.stringValue.flatMap(PlayerState.init(rawValue:))
    }

    /// Compiles the scripts and asks for the player state, which is what
    /// triggers the Automation prompt.
    @MainActor public func prepare() async {
        _ = playerState()
    }

    @MainActor public func pauseIfPlaying() async -> PauseReceipt? {
        guard playerState() == .playing, run(.pause) != nil else { return nil }
        return PauseReceipt(controller: id)
    }

    /// A user who resumed playback during the call keeps it: only a still paused
    /// player is started again.
    @MainActor public func resume(_ receipt: PauseReceipt) async {
        guard receipt.controller == id, playerState() == .paused else { return }
        _ = run(.play)
    }

    fileprivate enum Command: String {
        case playerState = "get player state as text"
        case pause
        case play
    }

    @MainActor private func run(_ command: Command) -> NSAppleEventDescriptor? {
        do {
            return try Scripts.script(for: command, bundleID: bundleID).execute()
        } catch {
            playerLogger.error("\(displayName, privacy: .public): \(error.logMessage, privacy: .public)")
            return nil
        }
    }
}

/// One compiled script per player and command, addressed by bundle ID so the
/// localised application name does not matter.
@MainActor
private enum Scripts {
    private struct Key: Hashable {
        let bundleID: String
        let command: ScriptablePlayerController.Command
    }

    private static var compiled: [Key: AppleScript] = [:]

    static func script(for command: ScriptablePlayerController.Command, bundleID: String) -> AppleScript {
        let key = Key(bundleID: bundleID, command: command)
        if let existing = compiled[key] { return existing }
        let script = AppleScript(
            """
            tell application id \(AppleScriptLiteral.string(bundleID))
                \(command.rawValue)
            end tell
            """
        )
        compiled[key] = script
        return script
    }
}
