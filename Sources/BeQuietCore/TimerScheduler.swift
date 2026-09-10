import Foundation

public protocol ScheduledTimer: Sendable {
    func cancel()
}

public protocol TimerScheduler: Sendable {
    /// Returns a handle; cancelling it prevents the action from firing.
    @MainActor func schedule(
        after seconds: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any ScheduledTimer
}

public struct DispatchTimerScheduler: TimerScheduler {
    public init() {}

    @MainActor public func schedule(
        after seconds: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any ScheduledTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated(action) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return WorkItemTimer(item: item)
    }
}

/// `@unchecked Sendable` because `DispatchWorkItem` is thread-safe but not
/// marked so; `cancel()` is the only thing ever called on it.
private struct WorkItemTimer: ScheduledTimer, @unchecked Sendable {
    let item: DispatchWorkItem

    func cancel() { item.cancel() }
}
