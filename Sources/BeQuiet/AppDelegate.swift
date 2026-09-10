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
    private let monitor = MicMonitor()
    private let micActivity = MicActivity()

    private var statusItemController: StatusItemController?
    private var eventTask: Task<Void, Never>?

    override init() {
        let store = SettingsStore()
        let controllers: [any MediaController] = [SpotifyController(), ChromeController()]
        self.store = store
        self.controllers = controllers
        coordinator = PauseCoordinator(controllers: controllers, settings: store.load())
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
            store: store
        )

        let settings = coordinator.settings
        appLogger.info(
            """
            started — enabled: \(settings.isEnabled, privacy: .public), \
            controllers: \(settings.enabledControllers.map(\.rawValue).sorted().joined(separator: ", "), privacy: .public), \
            debounce: \(settings.debounceSeconds, privacy: .public)s, \
            resume delay: \(settings.resumeDelaySeconds, privacy: .public)s
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
            appLogger.info("terminating")
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

        // `start()` reports transitions only, so the current state is fed in by hand.
        let initial = monitor.snapshot()
        micActivity.update(initial.activeProcesses)
        coordinator.micActivityChanged(isActive: initial.micActive)
        appLogger.info("initial mic state: \(initial.micActive, privacy: .public)")

        eventTask = Task { [weak self] in
            for await event in events {
                guard case let .micActivityChanged(isActive, reason, snapshot) = event else { continue }
                guard let self else { return }
                appLogger.debug("mic \(isActive, privacy: .public) — \(reason, privacy: .public)")
                micActivity.update(snapshot.activeProcesses)
                coordinator.micActivityChanged(isActive: isActive)
            }
        }
    }
}
