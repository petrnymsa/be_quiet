import Foundation
import MediaControl

public struct Settings: Hashable, Sendable {
    /// The Android Emulator holds the microphone for its whole lifetime, on
    /// Apple silicon and on Intel, windowed or `-no-window`; without this every
    /// emulator session would look like a call.
    public static let defaultIgnoredProcesses: Set<String> = [
        "qemu-system-aarch64",
        "qemu-system-aarch64-headless",
        "qemu-system-x86_64",
        "qemu-system-x86_64-headless",
    ]

    public var isEnabled = true
    public var debounceSeconds: TimeInterval = 2
    public var resumeDelaySeconds: TimeInterval = 3
    public var enabledControllers: Set<MediaControllerID> = [.spotify, .appleMusic, .chrome, .safari]
    /// Bundle IDs or executable names that never count as microphone activity.
    public var ignoredProcesses: Set<String> = Settings.defaultIgnoredProcesses

    public init(
        isEnabled: Bool = true,
        debounceSeconds: TimeInterval = 2,
        resumeDelaySeconds: TimeInterval = 3,
        enabledControllers: Set<MediaControllerID> = [.spotify, .appleMusic, .chrome, .safari],
        ignoredProcesses: Set<String> = Settings.defaultIgnoredProcesses
    ) {
        self.isEnabled = isEnabled
        self.debounceSeconds = debounceSeconds
        self.resumeDelaySeconds = resumeDelaySeconds
        self.enabledControllers = enabledControllers
        self.ignoredProcesses = ignoredProcesses
    }
}

/// `UserDefaults`-backed settings. Missing keys fall back to the defaults of
/// `Settings`, so a fresh installation needs no migration.
///
/// `@unchecked Sendable` because `UserDefaults` is thread-safe but not marked so.
public final class SettingsStore: @unchecked Sendable {
    /// Controllers BeQuiet knows about; every one of them is on by default.
    private static let knownControllers: [MediaControllerID] = [.spotify, .appleMusic, .chrome, .safari]

    private enum Key {
        static let enabled = "enabled"
        static let debounceSeconds = "debounceSeconds"
        static let resumeDelaySeconds = "resumeDelaySeconds"
        static let ignoredProcesses = "ignoredProcesses"

        static func controller(_ id: MediaControllerID) -> String { "controller.\(id.rawValue)" }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        let fallback = Settings()
        return Settings(
            isEnabled: defaults.bool(Key.enabled, or: fallback.isEnabled),
            debounceSeconds: defaults.double(Key.debounceSeconds, or: fallback.debounceSeconds),
            resumeDelaySeconds: defaults.double(Key.resumeDelaySeconds, or: fallback.resumeDelaySeconds),
            enabledControllers: Set(
                Self.knownControllers.filter { defaults.bool(Key.controller($0), or: true) }
            ),
            ignoredProcesses: defaults.strings(Key.ignoredProcesses, or: fallback.ignoredProcesses)
        )
    }

    public func save(_ settings: Settings) {
        defaults.set(settings.isEnabled, forKey: Key.enabled)
        defaults.set(settings.debounceSeconds, forKey: Key.debounceSeconds)
        defaults.set(settings.resumeDelaySeconds, forKey: Key.resumeDelaySeconds)
        for id in Self.knownControllers {
            defaults.set(settings.enabledControllers.contains(id), forKey: Key.controller(id))
        }
        defaults.set(settings.ignoredProcesses.sorted(), forKey: Key.ignoredProcesses)
    }
}

private extension UserDefaults {
    func bool(_ key: String, or fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }

    func double(_ key: String, or fallback: TimeInterval) -> TimeInterval {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }

    /// An empty array is a deliberate "the user cleared the list", so only a
    /// missing key falls back to the default.
    func strings(_ key: String, or fallback: Set<String>) -> Set<String> {
        guard let values = stringArray(forKey: key) else { return fallback }
        return Set(values)
    }
}
