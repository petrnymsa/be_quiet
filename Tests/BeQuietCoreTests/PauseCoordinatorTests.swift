import Foundation
import MediaControl
import MicMonitor
import Testing

import BeQuietCore

@Suite("PauseCoordinator")
@MainActor
struct PauseCoordinatorTests {
    @Test("the elapsed debounce timer pauses the enabled controllers")
    func pausesAfterDebounce() async {
        let spotify = FakeController(id: .spotify, pauseResult: .spotify)
        let ignored = FakeController(id: .fake, pauseResult: .fake)
        let scheduler = FakeScheduler()
        let coordinator = PauseCoordinator(
            controllers: [spotify, ignored],
            settings: .test(debounce: 2),
            scheduler: scheduler
        )

        coordinator.micActivityChanged(isActive: true)
        #expect(coordinator.phase == .arming)
        #expect(scheduler.pending.map(\.seconds) == [2])

        scheduler.fireNext()
        #expect(coordinator.phase == .pausing)
        #expect(await waitUntil { coordinator.phase == .paused })
        #expect(spotify.pauseCallCount == 1)
        #expect(ignored.pauseCallCount == 0)
        #expect(coordinator.heldReceipts == [.spotify])
    }

    @Test("the elapsed resume timer resumes the held receipt")
    func resumesAfterDelay() async {
        let spotify = FakeController(id: .spotify, pauseResult: .spotify)
        let scheduler = FakeScheduler()
        let coordinator = PauseCoordinator(
            controllers: [spotify],
            settings: .test(resumeDelay: 3),
            scheduler: scheduler
        )

        coordinator.micActivityChanged(isActive: true)
        scheduler.fireNext()
        #expect(await waitUntil { coordinator.phase == .paused })

        coordinator.micActivityChanged(isActive: false)
        #expect(coordinator.phase == .resumePending)
        #expect(scheduler.pending.map(\.seconds) == [3])

        scheduler.fireNext()
        #expect(coordinator.phase == .idle)
        #expect(await waitUntil { spotify.resumed == [.spotify] })
        #expect(coordinator.heldReceipts.isEmpty)
    }

    @Test("a mic drop-out cancels the resume timer and resumes nothing")
    func micDropOutCancelsResume() async {
        let spotify = FakeController(id: .spotify, pauseResult: .spotify)
        let scheduler = FakeScheduler()
        let coordinator = PauseCoordinator(
            controllers: [spotify],
            settings: .test(),
            scheduler: scheduler
        )

        coordinator.micActivityChanged(isActive: true)
        scheduler.fireNext()
        #expect(await waitUntil { coordinator.phase == .paused })

        coordinator.micActivityChanged(isActive: false)
        coordinator.micActivityChanged(isActive: true)
        #expect(coordinator.phase == .paused)
        #expect(scheduler.pending.isEmpty)
        #expect(spotify.resumed.isEmpty)
    }

    @Test("shutdown resumes what is held and stops reacting")
    func shutdownResumes() async {
        let spotify = FakeController(id: .spotify, pauseResult: .spotify)
        let scheduler = FakeScheduler()
        let coordinator = PauseCoordinator(
            controllers: [spotify],
            settings: .test(),
            scheduler: scheduler
        )

        coordinator.micActivityChanged(isActive: true)
        scheduler.fireNext()
        #expect(await waitUntil { coordinator.phase == .paused })

        await coordinator.shutdown()
        #expect(spotify.resumed == [.spotify])
        #expect(coordinator.heldReceipts.isEmpty)

        coordinator.micActivityChanged(isActive: false)
        #expect(scheduler.pending.isEmpty)
    }

    @Test("the mic event stream drives the coordinator until it ends")
    func consumesMicEvents() async {
        let scheduler = FakeScheduler()
        let coordinator = PauseCoordinator(
            controllers: [FakeController(id: .spotify, pauseResult: .spotify)],
            settings: .test(),
            scheduler: scheduler
        )

        let (events, continuation) = AsyncStream<MicEvent>.makeStream()
        let snapshot = MicSnapshot(devices: [], processes: [], usesDeviceLevelFallback: false)
        continuation.yield(.deviceLevelActivityChanged(isActive: true))
        continuation.yield(.micActivityChanged(isActive: true, reason: "test", snapshot: snapshot))
        continuation.finish()

        await coordinator.run(events)
        #expect(coordinator.isMicActive)
        #expect(coordinator.phase == .arming)
        #expect(scheduler.pending.count == 1)
    }

    @Test("turning a controller off resumes it immediately")
    func disablingControllerResumes() async {
        let spotify = FakeController(id: .spotify, pauseResult: .spotify)
        let scheduler = FakeScheduler()
        let coordinator = PauseCoordinator(
            controllers: [spotify],
            settings: .test(),
            scheduler: scheduler
        )

        coordinator.micActivityChanged(isActive: true)
        scheduler.fireNext()
        #expect(await waitUntil { coordinator.phase == .paused })

        coordinator.settings = .test(controllers: [])
        #expect(await waitUntil { spotify.resumed == [.spotify] })
        #expect(coordinator.phase == .paused)
        #expect(coordinator.heldReceipts.isEmpty)
    }
}
