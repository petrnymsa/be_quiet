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
        /// The processes counting as microphone activity right now.
        case micProcessesChanged(Set<String>)
        /// Seeds the baseline without triggering anything (startup, or
        /// re-enabling).
        case baselineProcesses(Set<String>)
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
    public private(set) var settings: Settings

    private var receipts: [PauseReceipt] = []
    /// The processes reported as holding the microphone, call or not.
    private var known: Set<String> = []
    /// The subset of `known` that started the current cycle. Processes already
    /// holding the microphone when a cycle begins are a baseline and are never
    /// in here, so they can neither start a call nor keep one alive.
    private var triggers: Set<String> = []

    public var heldReceipts: [PauseReceipt] { receipts }

    public var activeProcesses: Set<String> { known }

    public var triggeringProcesses: Set<String> { triggers }

    public var isMicActive: Bool { !known.isEmpty }

    public init(settings: Settings) {
        self.settings = settings
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .micProcessesChanged(active): processesChanged(to: active)
        case let .baselineProcesses(active): seedBaseline(active)
        case .debounceElapsed: debounceElapsed()
        case .resumeDelayElapsed: resumeDelayElapsed()
        case let .pauseCompleted(receipts): pauseCompleted(receipts)
        case let .settingsChanged(settings): settingsChanged(to: settings)
        }
    }

    // MARK: - Microphone

    private mutating func seedBaseline(_ active: Set<String>) -> [Effect] {
        known = active
        return []
    }

    private mutating func processesChanged(to new: Set<String>) -> [Effect] {
        let joined = new.subtracting(known)
        let left = known.subtracting(new)
        known = new

        // In `idle` nothing is in flight, so whoever joins now is what started
        // this cycle; a running cycle only gains and loses members.
        triggers = phase == .idle ? joined : triggers.subtracting(left).union(joined)

        // Microphone users are tracked even while disabled, so re-enabling
        // knows the baseline.
        guard settings.isEnabled else { return [] }

        switch phase {
        case .idle:
            guard !triggers.isEmpty else { return [] }
            phase = .arming
            return [.startDebounce(settings.debounceSeconds)]

        case .arming where triggers.isEmpty:
            phase = .idle
            return [.cancelDebounce]

        case .paused where triggers.isEmpty:
            phase = .resumePending
            return [.startResumeDelay(settings.resumeDelaySeconds)]

        case .resumePending where !triggers.isEmpty:
            // Reconnect, audio device switch, or a second application joining:
            // keep everything paused.
            phase = .paused
            return [.cancelResumeDelay]

        // While pausing the transition is deferred to `.pauseCompleted`, which
        // reads `triggers`.
        case .arming, .pausing, .paused, .resumePending:
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
        // Whoever is still holding the microphone becomes the next baseline.
        triggers = []
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
        guard !triggers.isEmpty else {
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
        triggers = []
        return effects
    }

    /// Whoever already holds the microphone becomes the baseline: a long-term
    /// holder must not start a cycle just because BeQuiet was switched on.
    private mutating func enable() -> [Effect] {
        triggers = []
        return []
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
