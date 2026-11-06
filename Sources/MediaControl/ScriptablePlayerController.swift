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
    private let scripts: Scripts

    public init(id: MediaControllerID, displayName: String, bundleID: String) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        scripts = Scripts(bundleID: bundleID)
    }

    /// Checked before every script: `tell application` launches its target, and
    /// BeQuiet must never start a player. Safe off the main thread.
    public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// `nil` when the player is not running or the state could not be read.
    public func playerState() async -> PlayerState? {
        guard isRunning else { return nil }
        do {
            return try await scripts.playerState.execute { $0.stringValue.flatMap(PlayerState.init(rawValue:)) }
        } catch {
            log(error)
            return nil
        }
    }

    /// Compiles the scripts and asks for the player state, which is what
    /// triggers the Automation prompt.
    public func prepare() async {
        _ = await playerState()
    }

    public func pauseIfPlaying() async -> PauseReceipt? {
        guard await playerState() == .playing, await run(scripts.pause) else { return nil }
        return PauseReceipt(controller: id)
    }

    /// A user who resumed playback during the call keeps it: only a still paused
    /// player is started again.
    public func resume(_ receipt: PauseReceipt) async {
        guard receipt.controller == id, await playerState() == .paused else { return }
        _ = await run(scripts.play)
    }

    /// `false` when the command failed, which is already logged.
    private func run(_ script: AppleScript) async -> Bool {
        do {
            try await script.execute()
            return true
        } catch {
            log(error)
            return false
        }
    }

    private func log(_ error: AppleScriptError) {
        playerLogger.error("\(displayName, privacy: .public): \(error.logMessage, privacy: .public)")
    }
}

/// One script per command, built with the controller and addressed by bundle ID
/// so the localised application name does not matter.
private struct Scripts {
    let playerState: AppleScript
    let pause: AppleScript
    let play: AppleScript

    init(bundleID: String) {
        func script(_ command: String) -> AppleScript {
            AppleScript(
                """
                tell application id \(AppleScriptLiteral.string(bundleID))
                    \(command)
                end tell
                """
            )
        }
        playerState = script("get player state as text")
        pause = script("pause")
        play = script("play")
    }
}
