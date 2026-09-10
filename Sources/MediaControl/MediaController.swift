public struct MediaControllerID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let spotify = MediaControllerID(rawValue: "spotify")
}

/// Describes what a controller paused so that exactly that can be resumed.
/// `items` are opaque to everyone but the controller that produced them.
public struct PauseReceipt: Hashable, Sendable {
    public let controller: MediaControllerID
    public let items: [String]

    public init(controller: MediaControllerID, items: [String] = []) {
        self.controller = controller
        self.items = items
    }
}

public protocol MediaController: Sendable {
    var id: MediaControllerID { get }
    var displayName: String { get }

    /// Pauses whatever is playing. `nil` means nothing was playing or the
    /// application is not running. Never launches the target application.
    @MainActor func pauseIfPlaying() async -> PauseReceipt?

    /// Resumes only what the receipt describes, and only if it is still paused.
    @MainActor func resume(_ receipt: PauseReceipt) async
}
