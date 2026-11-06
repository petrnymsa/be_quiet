import AppKit
import BeQuietCore
import MediaControl
import MicMonitor
import os

let appLogger = Logger(subsystem: "cz.nymsa.BeQuiet", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: SettingsStore
    private let controllers: [any MediaController]
    private let coordinator: PauseCoordinator
    private let monitor: MicMonitor
    private let micActivity = MicActivity()

    private var statusItemController: StatusItemController?
    private var eventTask: Task<Void, Never>?

    override init() {
        let store = SettingsStore()
        let controllers: [any MediaController] = [
            ScriptablePlayerController.spotify,
            ScriptablePlayerController.appleMusic,
            BrowserController.chrome,
            BrowserController.safari,
        ]
        let settings = store.load()
        self.store = store
        self.controllers = controllers
        coordinator = PauseCoordinator(controllers: controllers, settings: settings)
        monitor = MicMonitor(ignoredProcesses: settings.effectiveIgnoredProcesses)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundle carries `LSUIElement`, but `swift run BeQuiet` has no
        // Info.plist and would otherwise show up in the Dock.
        NSApp.setActivationPolicy(.accessory)

        statusItemController = StatusItemController(
            coordinator: coordinator,
            controllers: controllers,
            micActivity: micActivity,
            store: store,
            onSettingsChanged: { [weak self] settings in
                self?.monitor.ignoredProcesses = settings.effectiveIgnoredProcesses
            }
        )

        let settings = coordinator.settings
        appLogger.notice(
            """
            started — enabled: \(settings.isEnabled, privacy: .public), \
            controllers: \(settings.enabledControllers.map(\.rawValue).sorted().joined(separator: ", "), privacy: .public), \
            debounce: \(settings.debounceSeconds, privacy: .public)s, \
            resume delay: \(settings.resumeDelaySeconds, privacy: .public)s, \
            ignoring: \(settings.effectiveIgnoredProcesses.sorted().joined(separator: ", "), privacy: .public)
            """
        )
        warmUpControllers()
        startMonitoring()
    }

    /// Anything BeQuiet paused is resumed before the process goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await coordinator.shutdown()
            monitor.stop()
            eventTask?.cancel()
            appLogger.notice("terminating")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Pipeline

    /// Compiling the scripts and reading the player state at launch keeps the
    /// first pause fast and moves the Automation prompts to a moment where the
    /// user is not on a call.
    private func warmUpControllers() {
        let enabled = coordinator.settings.enabledControllers
        Task {
            for controller in controllers where enabled.contains(controller.id) {
                await controller.prepare()
            }
            appLogger.debug("controllers prepared")
        }
    }

    private func startMonitoring() {
        let events = monitor.start()

        // `start()` reports transitions only, so the current state is fed in by
        // hand — as a baseline, so a process that was already capturing when
        // BeQuiet started never counts as a call.
        let initial = monitor.snapshot()
        micActivity.update(initial)
        coordinator.seedBaseline(initial.activeProcessKeys)
        appLogger.notice(
            "initial microphone users: \(initial.activeProcessKeys.sorted().joined(separator: ", "), privacy: .public)"
        )

        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case let .micProcessesChanged(active, reason, snapshot):
                    appLogger.notice(
                        "microphone users: \(active.sorted().joined(separator: ", "), privacy: .public) — \(reason, privacy: .public)"
                    )
                    micActivity.update(snapshot)
                    coordinator.micProcessesChanged(active)

                case let .processListChanged(snapshot):
                    micActivity.update(snapshot)

                // An ignored process starting or stopping input leaves the
                // aggregate alone, so the menu is refreshed from these too.
                case .processRunningChanged:
                    micActivity.update(monitor.snapshot())

                case .deviceListChanged, .deviceRunningChanged, .deviceLevelActivityChanged:
                    break
                }
            }
        }
    }
}
