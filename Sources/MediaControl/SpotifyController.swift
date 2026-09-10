import AppKit
import Foundation
import os

let spotifyLogger = Logger(subsystem: "cz.nymsa.BeQuiet", category: "spotify")

public enum SpotifyPlayerState: String, Sendable, CustomStringConvertible {
    case playing
    case paused
    case stopped

    public var description: String { rawValue }
}

public struct SpotifyController: MediaController {
    private static let bundleID = "com.spotify.client"

    public let id = MediaControllerID.spotify
    public let displayName = "Spotify"

    public init() {}

    /// Checked before every script: `tell application` launches its target, and
    /// BeQuiet must never start Spotify.
    @MainActor public var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// `nil` when Spotify is not running or the state could not be read.
    @MainActor public func playerState() -> SpotifyPlayerState? {
        guard isRunning, let result = run(Scripts.playerState) else { return nil }
        return result.stringValue.flatMap(SpotifyPlayerState.init(rawValue:))
    }

    @MainActor public func pauseIfPlaying() async -> PauseReceipt? {
        guard playerState() == .playing, run(Scripts.pause) != nil else { return nil }
        return PauseReceipt(controller: id)
    }

    /// A user who resumed playback during the call keeps it: only a still paused
    /// player is started again.
    @MainActor public func resume(_ receipt: PauseReceipt) async {
        guard receipt.controller == id, playerState() == .paused else { return }
        _ = run(Scripts.play)
    }

    @MainActor private func run(_ script: AppleScript) -> NSAppleEventDescriptor? {
        do {
            return try script.execute()
        } catch {
            spotifyLogger.error("\(error.logMessage, privacy: .public)")
            return nil
        }
    }
}

/// Addressed by bundle ID so the localised application name does not matter.
@MainActor
private enum Scripts {
    static let playerState = AppleScript(tell("get player state as text"))
    static let pause = AppleScript(tell("pause"))
    static let play = AppleScript(tell("play"))

    private static func tell(_ command: String) -> String {
        """
        tell application id "com.spotify.client"
            \(command)
        end tell
        """
    }
}
