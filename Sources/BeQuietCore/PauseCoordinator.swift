import Foundation
import MediaControl
import MicMonitor
import Observation
import os

let coordinatorLogger = Logger(subsystem: "cz.nymsa.BeQuiet", category: "coordinator")

/// Runs `PauseStateMachine`: turns its effects into timers and controller calls
/// and publishes its state for the UI. All policy lives in the machine.
@MainActor
@Observable
public final class PauseCoordinator {
    public private(set) var phase: PausePhase
    public private(set) var isMicActive: Bool
    public private(set) var heldReceipts: [PauseReceipt]

    public var settings: Settings {
        didSet { handle(.settingsChanged(settings)) }
    }

    @ObservationIgnored private var machine: PauseStateMachine
    @ObservationIgnored private let controllers: [any MediaController]
    @ObservationIgnored private let scheduler: any TimerScheduler
    @ObservationIgnored private let onTransition: ((PausePhase, PausePhase) -> Void)?
    @ObservationIgnored private var debounceTimer: (any ScheduledTimer)?
    @ObservationIgnored private var resumeTimer: (any ScheduledTimer)?
    @ObservationIgnored private var isShutDown = false

    public init(
        controllers: [any MediaController],
        settings: Settings,
        scheduler: any TimerScheduler = DispatchTimerScheduler(),
        onTransition: ((PausePhase, PausePhase) -> Void)? = nil
    ) {
        let machine = PauseStateMachine(settings: settings)
        self.machine = machine
        self.controllers = controllers
        self.scheduler = scheduler
        self.onTransition = onTransition
        self.settings = settings
        phase = machine.phase
        isMicActive = machine.isMicActive
        heldReceipts = machine.heldReceipts
    }

    /// Feed from any mic source. Idempotent.
    public func micProcessesChanged(_ active: Set<String>) {
        handle(.micProcessesChanged(active))
    }

    /// Takes the processes already holding the microphone as the baseline, so
    /// none of them starts a pause cycle.
    public func seedBaseline(_ active: Set<String>) {
        handle(.baselineProcesses(active))
    }

    /// Consumes `MicMonitor` events until the stream ends.
    public func run(_ events: AsyncStream<MicEvent>) async {
        for await event in events {
            guard case let .micProcessesChanged(active, _, _) = event else { continue }
            micProcessesChanged(active)
        }
    }

    /// Resumes anything held and stops reacting to further events. Terminal:
    /// the coordinator is not usable afterwards.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        cancelTimers()

        let held = heldReceipts
        heldReceipts = []
        coordinatorLogger.notice("shutdown, resuming \(held.count) receipt(s)")
        await resume(held)
    }

    // MARK: - Machine

    private func handle(_ event: PauseStateMachine.Event) {
        guard !isShutDown else { return }

        let previous = machine.phase
        let previousProcesses = machine.activeProcesses
        let effects = machine.handle(event)
        phase = machine.phase
        isMicActive = machine.isMicActive
        heldReceipts = machine.heldReceipts

        if previous != machine.phase {
            coordinatorLogger.notice(
                """
                \(previous, privacy: .public) → \(self.machine.phase, privacy: .public) \
                (\(event.reason(since: previousProcesses), privacy: .public))
                """
            )
            onTransition?(previous, machine.phase)
        }
        for effect in effects { execute(effect) }
    }

    private func execute(_ effect: PauseStateMachine.Effect) {
        switch effect {
        case let .startDebounce(seconds):
            debounceTimer?.cancel()
            debounceTimer = scheduler.schedule(after: seconds) { [weak self] in
                self?.debounceTimer = nil
                self?.handle(.debounceElapsed)
            }

        case .cancelDebounce:
            debounceTimer?.cancel()
            debounceTimer = nil

        case let .startResumeDelay(seconds):
            resumeTimer?.cancel()
            resumeTimer = scheduler.schedule(after: seconds) { [weak self] in
                self?.resumeTimer = nil
                self?.handle(.resumeDelayElapsed)
            }

        case .cancelResumeDelay:
            resumeTimer?.cancel()
            resumeTimer = nil

        case let .pause(ids):
            // Init order, not set order, so the receipts come back predictably.
            let targets = controllers.filter { ids.contains($0.id) }
            Task { [weak self] in
                var receipts: [PauseReceipt] = []
                for controller in targets {
                    guard let receipt = await controller.pauseIfPlaying() else { continue }
                    receipts.append(receipt)
                }
                self?.handle(.pauseCompleted(receipts))
            }

        case let .resume(receipts):
            Task { [weak self] in
                await self?.resume(receipts)
            }
        }
    }

    private func resume(_ receipts: [PauseReceipt]) async {
        for receipt in receipts {
            guard let controller = controllers.first(where: { $0.id == receipt.controller }) else { continue }
            await controller.resume(receipt)
        }
    }

    private func cancelTimers() {
        debounceTimer?.cancel()
        debounceTimer = nil
        resumeTimer?.cancel()
        resumeTimer = nil
    }
}

private extension PauseStateMachine.Event {
    /// Naming who joined and who left is the whole diagnosis when a pause does
    /// not happen, so the keys go into the log, not just "processes changed".
    func reason(since previous: Set<String>) -> String {
        switch self {
        case let .micProcessesChanged(active):
            let changes = [
                Self.list("joined", active.subtracting(previous)),
                Self.list("left", previous.subtracting(active)),
            ].compactMap { $0 }
            return changes.isEmpty ? "microphone users unchanged" : changes.joined(separator: ", ")
        case let .baselineProcesses(active):
            return Self.list("baseline", active) ?? "baseline: nothing holds the microphone"
        case .debounceElapsed: return "debounce elapsed"
        case .resumeDelayElapsed: return "resume delay elapsed"
        case let .pauseCompleted(receipts): return "paused \(receipts.count) controller(s)"
        case .settingsChanged: return "settings changed"
        }
    }

    static func list(_ label: String, _ keys: Set<String>) -> String? {
        guard !keys.isEmpty else { return nil }
        return "\(label): \(keys.sorted().joined(separator: ", "))"
    }
}
