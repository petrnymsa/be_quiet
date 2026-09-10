import Foundation
import MediaControl

import BeQuietCore

extension MediaControllerID {
    /// Stands in for a second controller (Chrome, later) in the tests.
    static let fake = MediaControllerID(rawValue: "test.fake")
}

extension PauseReceipt {
    static let spotify = PauseReceipt(controller: .spotify)
    static let fake = PauseReceipt(controller: .fake)
}

extension Settings {
    static func test(
        isEnabled: Bool = true,
        debounce: TimeInterval = 2,
        resumeDelay: TimeInterval = 3,
        controllers: Set<MediaControllerID> = [.spotify]
    ) -> Settings {
        Settings(
            isEnabled: isEnabled,
            debounceSeconds: debounce,
            resumeDelaySeconds: resumeDelay,
            enabledControllers: controllers
        )
    }
}

extension PauseStateMachine {
    /// Drives the machine into `pausing`.
    mutating func pauseNow() {
        _ = handle(.micActive)
        _ = handle(.debounceElapsed)
    }

    /// Drives the machine into `paused`, holding `receipts`.
    mutating func pause(receipts: [PauseReceipt]) {
        pauseNow()
        _ = handle(.pauseCompleted(receipts))
    }
}

/// Yields until `condition` holds, so a test can wait for the coordinator's
/// pause/resume tasks without a real clock. Returns false if it never holds.
@MainActor
func waitUntil(iterations: Int = 100, _ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
final class FakeScheduler: TimerScheduler {
    @MainActor
    final class Entry {
        let seconds: TimeInterval
        let action: @MainActor @Sendable () -> Void
        var isCancelled = false

        init(seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
            self.seconds = seconds
            self.action = action
        }
    }

    private(set) var entries: [Entry] = []

    var pending: [Entry] { entries.filter { !$0.isCancelled } }

    func schedule(
        after seconds: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any ScheduledTimer {
        let entry = Entry(seconds: seconds, action: action)
        entries.append(entry)
        return Handle { MainActor.assumeIsolated { entry.isCancelled = true } }
    }

    /// Fires the oldest timer that has neither fired nor been cancelled.
    func fireNext() {
        guard let entry = pending.first else { return }
        entry.isCancelled = true
        entry.action()
    }

    private struct Handle: ScheduledTimer {
        let onCancel: @Sendable () -> Void

        func cancel() { onCancel() }
    }
}

@MainActor
final class FakeController: MediaController {
    let id: MediaControllerID
    let displayName: String

    var pauseResult: PauseReceipt?
    private(set) var pauseCallCount = 0
    private(set) var resumed: [PauseReceipt] = []

    init(id: MediaControllerID, pauseResult: PauseReceipt?) {
        self.id = id
        displayName = id.rawValue
        self.pauseResult = pauseResult
    }

    func pauseIfPlaying() async -> PauseReceipt? {
        pauseCallCount += 1
        return pauseResult
    }

    func resume(_ receipt: PauseReceipt) async {
        resumed.append(receipt)
    }
}
