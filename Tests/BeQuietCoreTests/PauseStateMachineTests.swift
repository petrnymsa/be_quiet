import Foundation
import MediaControl
import Testing

import BeQuietCore

@Suite("PauseStateMachine")
struct PauseStateMachineTests {
    // MARK: - Debounce

    @Test("mic activity arms the debounce timer")
    func armsOnMicActivity() {
        var machine = PauseStateMachine(settings: .test())

        #expect(machine.handle(.micActive) == [.startDebounce(2)])
        #expect(machine.phase == .arming)
        #expect(machine.isMicActive)
    }

    @Test("a burst shorter than the debounce is ignored")
    func shortBurstIsIgnored() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.micActive)

        #expect(machine.handle(.micInactive) == [.cancelDebounce])
        #expect(machine.phase == .idle)
        #expect(machine.handle(.debounceElapsed) == [])
        #expect(machine.phase == .idle)
    }

    @Test("the elapsed debounce pauses every enabled controller")
    func debouncePausesEnabledControllers() {
        var machine = PauseStateMachine(settings: .test(controllers: [.spotify, .fake]))
        _ = machine.handle(.micActive)

        #expect(machine.handle(.debounceElapsed) == [.pause([.spotify, .fake])])
        #expect(machine.phase == .pausing)
    }

    @Test("without enabled controllers there is nothing to pause")
    func noEnabledControllers() {
        var machine = PauseStateMachine(settings: .test(controllers: []))
        _ = machine.handle(.micActive)

        #expect(machine.handle(.debounceElapsed) == [])
        #expect(machine.phase == .paused)
        #expect(machine.heldReceipts.isEmpty)
    }

    // MARK: - Pausing

    @Test("completed pausing holds the receipts")
    func pauseCompletedHoldsReceipts() {
        var machine = PauseStateMachine(settings: .test())
        machine.pauseNow()

        #expect(machine.handle(.pauseCompleted([.spotify])) == [])
        #expect(machine.phase == .paused)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("mic going off while pausing defers the resume delay to the completion")
    func micOffWhilePausing() {
        var machine = PauseStateMachine(settings: .test())
        machine.pauseNow()

        #expect(machine.handle(.micInactive) == [])
        #expect(machine.phase == .pausing)
        #expect(machine.handle(.pauseCompleted([.spotify])) == [.startResumeDelay(3)])
        #expect(machine.phase == .resumePending)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("mic coming back while pausing completes as usual")
    func micBackWhilePausing() {
        var machine = PauseStateMachine(settings: .test())
        machine.pauseNow()
        _ = machine.handle(.micInactive)

        #expect(machine.handle(.micActive) == [])
        #expect(machine.handle(.pauseCompleted([.spotify])) == [])
        #expect(machine.phase == .paused)
    }

    // MARK: - Resume

    @Test("mic going off while paused starts the resume delay")
    func pausedMicOffStartsResumeDelay() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify])

        #expect(machine.handle(.micInactive) == [.startResumeDelay(3)])
        #expect(machine.phase == .resumePending)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("a mic drop-out mid call keeps the receipts and resumes nothing")
    func micDropOutKeepsReceipts() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify])
        _ = machine.handle(.micInactive)

        #expect(machine.handle(.micActive) == [.cancelResumeDelay])
        #expect(machine.phase == .paused)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("the elapsed resume delay resumes the receipts in pause order")
    func resumeDelayResumesInOrder() {
        var machine = PauseStateMachine(settings: .test(controllers: [.spotify, .fake]))
        machine.pause(receipts: [.fake, .spotify])
        _ = machine.handle(.micInactive)

        #expect(machine.handle(.resumeDelayElapsed) == [.resume([.fake, .spotify])])
        #expect(machine.phase == .idle)
        #expect(machine.heldReceipts.isEmpty)
    }

    @Test("nothing playing means nothing to resume")
    func nothingPausedResumesNothing() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [])
        #expect(machine.phase == .paused)

        #expect(machine.handle(.micInactive) == [.startResumeDelay(3)])
        #expect(machine.handle(.resumeDelayElapsed) == [])
        #expect(machine.phase == .idle)
    }

    // MARK: - Idempotence

    @Test("repeated mic events change nothing")
    func repeatedMicEventsAreIdempotent() {
        var machine = PauseStateMachine(settings: .test())
        #expect(machine.handle(.micInactive) == [])
        #expect(machine.phase == .idle)

        _ = machine.handle(.micActive)
        #expect(machine.handle(.micActive) == [])
        #expect(machine.phase == .arming)

        machine.pause(receipts: [.spotify])
        #expect(machine.handle(.micActive) == [])
        #expect(machine.phase == .paused)
    }

    @Test("timer events outside their phase change nothing")
    func strayTimerEventsAreIgnored() {
        var machine = PauseStateMachine(settings: .test())

        #expect(machine.handle(.resumeDelayElapsed) == [])
        #expect(machine.handle(.debounceElapsed) == [])
        #expect(machine.phase == .idle)
    }

    // MARK: - Settings

    @Test("disabling cancels the debounce timer")
    func disablingCancelsDebounce() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.micActive)

        #expect(machine.handle(.settingsChanged(.test(isEnabled: false))) == [.cancelDebounce])
        #expect(machine.phase == .idle)
    }

    @Test("disabling while paused resumes immediately")
    func disablingWhilePausedResumes() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify])

        #expect(machine.handle(.settingsChanged(.test(isEnabled: false))) == [.resume([.spotify])])
        #expect(machine.phase == .idle)
        #expect(machine.heldReceipts.isEmpty)
    }

    @Test("disabling while the resume delay runs cancels it and resumes")
    func disablingWhileResumePendingCancelsAndResumes() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify])
        _ = machine.handle(.micInactive)

        #expect(machine.handle(.settingsChanged(.test(isEnabled: false)))
            == [.cancelResumeDelay, .resume([.spotify])])
        #expect(machine.phase == .idle)
    }

    @Test("while disabled the microphone is tracked but never acted on")
    func disabledIgnoresMicActivity() {
        var machine = PauseStateMachine(settings: .test(isEnabled: false))

        #expect(machine.handle(.micActive) == [])
        #expect(machine.isMicActive)
        #expect(machine.phase == .idle)
        #expect(machine.handle(.debounceElapsed) == [])
        #expect(machine.handle(.micInactive) == [])
        #expect(machine.phase == .idle)
    }

    @Test("re-enabling with the mic already active arms as if it had just started")
    func reEnablingWithActiveMicArms() {
        var machine = PauseStateMachine(settings: .test(isEnabled: false))
        _ = machine.handle(.micActive)

        #expect(machine.handle(.settingsChanged(.test())) == [.startDebounce(2)])
        #expect(machine.phase == .arming)
    }

    @Test("re-enabling with an idle mic stays idle")
    func reEnablingWithIdleMicStaysIdle() {
        var machine = PauseStateMachine(settings: .test(isEnabled: false))

        #expect(machine.handle(.settingsChanged(.test())) == [])
        #expect(machine.phase == .idle)
    }

    @Test("a controller turned off releases its receipt at once")
    func disablingControllerResumesItsReceipt() {
        var machine = PauseStateMachine(settings: .test(controllers: [.spotify, .fake]))
        machine.pause(receipts: [.spotify, .fake])

        #expect(machine.handle(.settingsChanged(.test(controllers: [.spotify]))) == [.resume([.fake])])
        #expect(machine.phase == .paused)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("new timings apply to the next timer, not to the running one")
    func changedTimingsDoNotRestartTimers() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.micActive)

        #expect(machine.handle(.settingsChanged(.test(debounce: 5, resumeDelay: 10))) == [])
        #expect(machine.phase == .arming)
        _ = machine.handle(.debounceElapsed)
        #expect(machine.handle(.pauseCompleted([.spotify])) == [])
        #expect(machine.handle(.micInactive) == [.startResumeDelay(10)])
    }

    // MARK: - Stale completion

    @Test("a completion arriving after the machine moved on resumes at once")
    func staleCompletionResumesImmediately() {
        var machine = PauseStateMachine(settings: .test())
        machine.pauseNow()
        _ = machine.handle(.settingsChanged(.test(isEnabled: false)))

        #expect(machine.handle(.pauseCompleted([.spotify])) == [.resume([.spotify])])
        #expect(machine.phase == .idle)
        #expect(machine.heldReceipts.isEmpty)
    }

    @Test("an empty stale completion resumes nothing")
    func emptyStaleCompletionDoesNothing() {
        var machine = PauseStateMachine(settings: .test())

        #expect(machine.handle(.pauseCompleted([])) == [])
        #expect(machine.phase == .idle)
    }
}
