import Foundation
import MediaControl
import Testing

import BeQuietCore

@Suite("PauseStateMachine")
struct PauseStateMachineTests {
    // MARK: - Baseline

    @Test("a baseline seeds the active processes without starting a cycle")
    func baselineStartsNothing() {
        var machine = PauseStateMachine(settings: .test())

        #expect(machine.handle(.baselineProcesses(["holder"])) == [])
        #expect(machine.phase == .idle)
        #expect(machine.isMicActive)
        #expect(machine.activeProcesses == ["holder"])
        #expect(machine.triggeringProcesses.isEmpty)
    }

    @Test("a baseline during a cycle leaves that cycle alone")
    func baselineDuringCycleKeepsTriggers() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])

        #expect(machine.handle(.baselineProcesses(["teams", "holder"])) == [])
        #expect(machine.phase == .paused)
        #expect(machine.triggeringProcesses == ["teams"])
        #expect(machine.activeProcesses == ["teams", "holder"])
    }

    // MARK: - Debounce

    @Test("a process joining arms the debounce timer")
    func joinArmsDebounce() {
        var machine = PauseStateMachine(settings: .test())

        #expect(machine.handle(.micProcessesChanged(["teams"])) == [.startDebounce(2)])
        #expect(machine.phase == .arming)
        #expect(machine.triggeringProcesses == ["teams"])
        #expect(machine.isMicActive)
    }

    @Test("a process only leaving while idle starts nothing")
    func departureWhileIdleStartsNothing() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.baselineProcesses(["holder"]))

        #expect(machine.handle(.micProcessesChanged([])) == [])
        #expect(machine.phase == .idle)
        #expect(!machine.isMicActive)
    }

    @Test("a process that was already holding the microphone never starts a cycle")
    func longLivedHolderNeverTriggers() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.baselineProcesses(["com.google.Chrome.helper"]))

        // The forgotten Meet tab keeps reporting; nothing joined, nothing happens.
        #expect(machine.handle(.micProcessesChanged(["com.google.Chrome.helper"])) == [])
        #expect(machine.phase == .idle)

        #expect(
            machine.handle(.micProcessesChanged(["com.google.Chrome.helper", "com.microsoft.teams2"]))
                == [.startDebounce(2)]
        )
        #expect(machine.triggeringProcesses == ["com.microsoft.teams2"])

        _ = machine.handle(.debounceElapsed)
        _ = machine.handle(.pauseCompleted([.spotify]))
        #expect(machine.phase == .paused)

        // The holder stays, but the call is over.
        #expect(machine.handle(.micProcessesChanged(["com.google.Chrome.helper"])) == [.startResumeDelay(3)])
        #expect(machine.phase == .resumePending)
    }

    @Test("the triggering process leaving while arming cancels the debounce")
    func triggerLeavingWhileArmingCancels() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.baselineProcesses(["holder"]))
        _ = machine.handle(.micProcessesChanged(["holder", "teams"]))

        #expect(machine.handle(.micProcessesChanged(["holder"])) == [.cancelDebounce])
        #expect(machine.phase == .idle)
        #expect(machine.triggeringProcesses.isEmpty)
    }

    @Test("the elapsed debounce pauses every enabled controller")
    func debouncePausesEnabledControllers() {
        var machine = PauseStateMachine(settings: .test(controllers: [.spotify, .fake]))
        _ = machine.handle(.micProcessesChanged(["teams"]))

        #expect(machine.handle(.debounceElapsed) == [.pause([.spotify, .fake])])
        #expect(machine.phase == .pausing)
    }

    @Test("without enabled controllers there is nothing to pause")
    func noEnabledControllers() {
        var machine = PauseStateMachine(settings: .test(controllers: []))
        _ = machine.handle(.micProcessesChanged(["teams"]))

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

    @Test("the call ending while pausing defers the resume delay to the completion")
    func callEndingWhilePausing() {
        var machine = PauseStateMachine(settings: .test())
        machine.pauseNow(triggeredBy: ["teams"])

        #expect(machine.handle(.micProcessesChanged([])) == [])
        #expect(machine.phase == .pausing)
        #expect(machine.handle(.pauseCompleted([.spotify])) == [.startResumeDelay(3)])
        #expect(machine.phase == .resumePending)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("the call coming back while pausing completes as usual")
    func callBackWhilePausing() {
        var machine = PauseStateMachine(settings: .test())
        machine.pauseNow(triggeredBy: ["teams"])
        _ = machine.handle(.micProcessesChanged([]))

        #expect(machine.handle(.micProcessesChanged(["teams"])) == [])
        #expect(machine.handle(.pauseCompleted([.spotify])) == [])
        #expect(machine.phase == .paused)
    }

    // MARK: - Resume

    @Test("the call ending while paused starts the resume delay")
    func pausedCallEndStartsResumeDelay() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])

        #expect(machine.handle(.micProcessesChanged([])) == [.startResumeDelay(3)])
        #expect(machine.phase == .resumePending)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("a second application joining an ongoing call joins its triggers")
    func secondApplicationJoinsTheCall() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])

        #expect(machine.handle(.micProcessesChanged(["teams", "slack"])) == [])
        #expect(machine.triggeringProcesses == ["teams", "slack"])

        #expect(machine.handle(.micProcessesChanged(["slack"])) == [])
        #expect(machine.phase == .paused)
        #expect(machine.handle(.micProcessesChanged([])) == [.startResumeDelay(3)])
    }

    @Test("a mic drop-out mid call keeps the receipts and resumes nothing")
    func micDropOutKeepsReceipts() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])
        _ = machine.handle(.micProcessesChanged([]))

        #expect(machine.handle(.micProcessesChanged(["teams"])) == [.cancelResumeDelay])
        #expect(machine.phase == .paused)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("another process joining while the resume delay runs keeps everything paused")
    func newProcessDuringResumeDelayKeepsPaused() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])
        _ = machine.handle(.micProcessesChanged([]))

        #expect(machine.handle(.micProcessesChanged(["slack"])) == [.cancelResumeDelay])
        #expect(machine.phase == .paused)
        #expect(machine.triggeringProcesses == ["slack"])
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("the elapsed resume delay resumes the receipts in pause order")
    func resumeDelayResumesInOrder() {
        var machine = PauseStateMachine(settings: .test(controllers: [.spotify, .fake]))
        machine.pause(receipts: [.fake, .spotify], triggeredBy: ["teams"])
        _ = machine.handle(.micProcessesChanged([]))

        #expect(machine.handle(.resumeDelayElapsed) == [.resume([.fake, .spotify])])
        #expect(machine.phase == .idle)
        #expect(machine.heldReceipts.isEmpty)
        #expect(machine.triggeringProcesses.isEmpty)
    }

    @Test("the elapsed resume delay keeps the processes still holding the microphone")
    func resumeDelayKeepsTheBaseline() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.baselineProcesses(["holder"]))
        machine.pause(receipts: [.spotify], triggeredBy: ["holder", "teams"])
        _ = machine.handle(.micProcessesChanged(["holder"]))

        #expect(machine.handle(.resumeDelayElapsed) == [.resume([.spotify])])
        #expect(machine.phase == .idle)
        #expect(machine.activeProcesses == ["holder"])
        #expect(machine.triggeringProcesses.isEmpty)
    }

    @Test("nothing playing means nothing to resume")
    func nothingPausedResumesNothing() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [], triggeredBy: ["teams"])
        #expect(machine.phase == .paused)

        #expect(machine.handle(.micProcessesChanged([])) == [.startResumeDelay(3)])
        #expect(machine.handle(.resumeDelayElapsed) == [])
        #expect(machine.phase == .idle)
    }

    // MARK: - Idempotence

    @Test("an unchanged set of processes changes nothing")
    func unchangedSetIsIdempotent() {
        var machine = PauseStateMachine(settings: .test())
        #expect(machine.handle(.micProcessesChanged([])) == [])
        #expect(machine.phase == .idle)

        _ = machine.handle(.micProcessesChanged(["teams"]))
        #expect(machine.handle(.micProcessesChanged(["teams"])) == [])
        #expect(machine.phase == .arming)

        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])
        #expect(machine.handle(.micProcessesChanged(["teams"])) == [])
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
        _ = machine.handle(.micProcessesChanged(["teams"]))

        #expect(machine.handle(.settingsChanged(.test(isEnabled: false))) == [.cancelDebounce])
        #expect(machine.phase == .idle)
        #expect(machine.triggeringProcesses.isEmpty)
    }

    @Test("disabling while paused resumes immediately")
    func disablingWhilePausedResumes() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])

        #expect(machine.handle(.settingsChanged(.test(isEnabled: false))) == [.resume([.spotify])])
        #expect(machine.phase == .idle)
        #expect(machine.heldReceipts.isEmpty)
    }

    @Test("disabling while the resume delay runs cancels it and resumes")
    func disablingWhileResumePendingCancelsAndResumes() {
        var machine = PauseStateMachine(settings: .test())
        machine.pause(receipts: [.spotify], triggeredBy: ["teams"])
        _ = machine.handle(.micProcessesChanged([]))

        #expect(machine.handle(.settingsChanged(.test(isEnabled: false)))
            == [.cancelResumeDelay, .resume([.spotify])])
        #expect(machine.phase == .idle)
    }

    @Test("while disabled the microphone is tracked but never acted on")
    func disabledIgnoresMicActivity() {
        var machine = PauseStateMachine(settings: .test(isEnabled: false))

        #expect(machine.handle(.micProcessesChanged(["teams"])) == [])
        #expect(machine.isMicActive)
        #expect(machine.phase == .idle)
        #expect(machine.handle(.debounceElapsed) == [])
        #expect(machine.handle(.micProcessesChanged([])) == [])
        #expect(machine.phase == .idle)
    }

    @Test("re-enabling with the microphone already held seeds the baseline instead of arming")
    func reEnablingSeedsTheBaseline() {
        var machine = PauseStateMachine(settings: .test(isEnabled: false))
        _ = machine.handle(.micProcessesChanged(["holder"]))

        #expect(machine.handle(.settingsChanged(.test())) == [])
        #expect(machine.phase == .idle)
        #expect(machine.isMicActive)
        #expect(machine.triggeringProcesses.isEmpty)

        // Only something joining afterwards is a call.
        #expect(machine.handle(.micProcessesChanged(["holder", "teams"])) == [.startDebounce(2)])
        #expect(machine.triggeringProcesses == ["teams"])
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
        machine.pause(receipts: [.spotify, .fake], triggeredBy: ["teams"])

        #expect(machine.handle(.settingsChanged(.test(controllers: [.spotify]))) == [.resume([.fake])])
        #expect(machine.phase == .paused)
        #expect(machine.heldReceipts == [.spotify])
    }

    @Test("new timings apply to the next timer, not to the running one")
    func changedTimingsDoNotRestartTimers() {
        var machine = PauseStateMachine(settings: .test())
        _ = machine.handle(.micProcessesChanged(["teams"]))

        #expect(machine.handle(.settingsChanged(.test(debounce: 5, resumeDelay: 10))) == [])
        #expect(machine.phase == .arming)
        _ = machine.handle(.debounceElapsed)
        #expect(machine.handle(.pauseCompleted([.spotify])) == [])
        #expect(machine.handle(.micProcessesChanged([])) == [.startResumeDelay(10)])
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
