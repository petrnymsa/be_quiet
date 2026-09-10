import Foundation
import MediaControl

public enum PausePhase: Hashable, Sendable, CustomStringConvertible {
    case idle
    case arming
    case pausing
    case paused
    case resumePending

    public var description: String {
        switch self {
        case .idle: "idle"
        case .arming: "arming"
        case .pausing: "pausing"
        case .paused: "paused"
        case .resumePending: "resumePending"
        }
    }
}

/// The whole pause/resume policy, free of timers, tasks and I/O: events in,
/// effects out. Everything that can go wrong in this feature can be tested here.
public struct PauseStateMachine: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        case micActive
        case micInactive
        case debounceElapsed
        case resumeDelayElapsed
        /// One receipt per controller that actually paused something.
        case pauseCompleted([PauseReceipt])
        case settingsChanged(Settings)
    }

    public enum Effect: Hashable, Sendable {
        case startDebounce(TimeInterval)
        case cancelDebounce
        case startResumeDelay(TimeInterval)
        case cancelResumeDelay
        /// Call `pauseIfPlaying()` on these, then feed back `.pauseCompleted`.
        case pause(Set<MediaControllerID>)
        case resume([PauseReceipt])
    }

    public private(set) var phase: PausePhase = .idle
    public private(set) var isMicActive = false
    public private(set) var settings: Settings

    private var receipts: [PauseReceipt] = []

    public var heldReceipts: [PauseReceipt] { receipts }

    public init(settings: Settings) {
        self.settings = settings
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .micActive: micActivityChanged(to: true)
        case .micInactive: micActivityChanged(to: false)
        case .debounceElapsed: debounceElapsed()
        case .resumeDelayElapsed: resumeDelayElapsed()
        case let .pauseCompleted(receipts): pauseCompleted(receipts)
        case let .settingsChanged(settings): settingsChanged(to: settings)
        }
    }

    // MARK: - Microphone

    private mutating func micActivityChanged(to isActive: Bool) -> [Effect] {
        guard isMicActive != isActive else { return [] }
        isMicActive = isActive
        // Mic state is tracked even while disabled, so re-enabling can act on it.
        guard settings.isEnabled else { return [] }

        switch (isActive, phase) {
        case (true, .idle):
            phase = .arming
            return [.startDebounce(settings.debounceSeconds)]

        case (true, .resumePending):
            // Reconnect or audio device switch: keep everything paused.
            phase = .paused
            return [.cancelResumeDelay]

        case (false, .arming):
            phase = .idle
            return [.cancelDebounce]

        case (false, .paused):
            phase = .resumePending
            return [.startResumeDelay(settings.resumeDelaySeconds)]

        // While pausing the transition is deferred to `.pauseCompleted`, which
        // reads `isMicActive`.
        default:
            return []
        }
    }

    // MARK: - Timers

    private mutating func debounceElapsed() -> [Effect] {
        guard settings.isEnabled, phase == .arming else { return [] }

        let controllers = settings.enabledControllers
        guard !controllers.isEmpty else {
            phase = .paused
            return []
        }
        phase = .pausing
        return [.pause(controllers)]
    }

    private mutating func resumeDelayElapsed() -> [Effect] {
        guard phase == .resumePending else { return [] }
        phase = .idle
        guard let held = takeReceipts() else { return [] }
        return [.resume(held)]
    }

    // MARK: - Pausing

    private mutating func pauseCompleted(_ completed: [PauseReceipt]) -> [Effect] {
        // A completion can arrive after the machine moved on (BeQuiet was
        // disabled while the controllers were still being asked). Nothing may
        // stay paused in that case.
        guard phase == .pausing else {
            return completed.isEmpty ? [] : [.resume(completed)]
        }

        receipts = completed
        guard isMicActive else {
            phase = .resumePending
            return [.startResumeDelay(settings.resumeDelaySeconds)]
        }
        phase = .paused
        return []
    }

    // MARK: - Settings

    private mutating func settingsChanged(to new: Settings) -> [Effect] {
        let previous = settings
        settings = new

        guard new.isEnabled else {
            return previous.isEnabled ? disable() : []
        }
        guard previous.isEnabled else {
            return enable()
        }
        return releaseDisabledControllers()
    }

    private mutating func disable() -> [Effect] {
        var effects: [Effect] = []
        switch phase {
        case .arming: effects.append(.cancelDebounce)
        case .resumePending: effects.append(.cancelResumeDelay)
        default: break
        }
        if let held = takeReceipts() {
            effects.append(.resume(held))
        }
        phase = .idle
        return effects
    }

    /// An already active microphone counts as a fresh activation.
    private mutating func enable() -> [Effect] {
        guard isMicActive else { return [] }
        phase = .arming
        return [.startDebounce(settings.debounceSeconds)]
    }

    private mutating func releaseDisabledControllers() -> [Effect] {
        let released = receipts.filter { !settings.enabledControllers.contains($0.controller) }
        guard !released.isEmpty else { return [] }
        receipts.removeAll { !settings.enabledControllers.contains($0.controller) }
        return [.resume(released)]
    }

    // MARK: - Receipts

    /// Clears the held receipts and returns them, or `nil` when none were held —
    /// resuming nothing is not worth an effect.
    private mutating func takeReceipts() -> [PauseReceipt]? {
        guard !receipts.isEmpty else { return nil }
        defer { receipts = [] }
        return receipts
    }
}
