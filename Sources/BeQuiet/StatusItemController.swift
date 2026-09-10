import AppKit
import BeQuietCore
import Foundation
import MediaControl
import Observation

/// The whole user interface: one status item, one menu, no windows.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let debouncePresets: [TimeInterval] = [0.5, 1, 2, 3, 5]
    private static let resumeDelayPresets: [TimeInterval] = [1, 2, 3, 5, 10]

    private let coordinator: PauseCoordinator
    private let controllers: [any MediaController]
    private let micActivity: MicActivity
    private let store: SettingsStore
    private let launchAtLogin = LaunchAtLogin()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(
        coordinator: PauseCoordinator,
        controllers: [any MediaController],
        micActivity: MicActivity,
        store: SettingsStore
    ) {
        self.coordinator = coordinator
        self.controllers = controllers
        self.micActivity = micActivity
        self.store = store
        super.init()

        // Enablement is decided here, not by target/action validation: the
        // status line and the Chrome warning are deliberately dead items.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        observe { [weak self] in self?.refreshStatusItem() }
    }

    // MARK: - Status item

    private func refreshStatusItem() {
        let presentation = self.presentation
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.tooltip
        )
        button.toolTip = presentation.tooltip
    }

    /// Runs `apply` and re-registers itself on every change of what it read, so
    /// the status item follows `phase` and `settings` without polling.
    /// `onChange` fires before the value is committed, hence the hop to the next
    /// main actor turn.
    private func observe(_ apply: @escaping @MainActor @Sendable () -> Void) {
        withObservationTracking {
            apply()
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observe(apply)
            }
        }
    }

    private var presentation: StatusPresentation {
        StatusPresentation(
            isEnabled: coordinator.settings.isEnabled,
            phase: coordinator.phase,
            pausedControllerNames: pausedControllerNames,
            micProcessNames: micActivity.processNames
        )
    }

    private var pausedControllerNames: [String] {
        coordinator.heldReceipts.compactMap { receipt in
            controllers.first { $0.id == receipt.controller }?.displayName
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = coordinator.settings
        menu.removeAllItems()

        menu.addItem(deadItem(presentation.statusText))
        menu.addItem(.separator())

        menu.addItem(
            checkbox("Enabled", isOn: settings.isEnabled, action: #selector(toggleEnabled))
        )
        for controller in controllers {
            menu.addItem(
                checkbox(
                    "Pause \(controller.displayName)",
                    isOn: settings.enabledControllers.contains(controller.id),
                    action: #selector(toggleController(_:)),
                    representedObject: controller.id
                )
            )
            if let warning = javaScriptWarning(for: controller) {
                menu.addItem(warning)
            }
        }
        menu.addItem(.separator())

        menu.addItem(
            presetSubmenu(
                "Debounce",
                presets: Self.debouncePresets,
                current: settings.debounceSeconds,
                action: #selector(setDebounce(_:))
            )
        )
        menu.addItem(
            presetSubmenu(
                "Resume delay",
                presets: Self.resumeDelayPresets,
                current: settings.resumeDelaySeconds,
                action: #selector(setResumeDelay(_:))
            )
        )
        menu.addItem(.separator())

        menu.addItem(launchAtLoginItem())
        let quit = NSMenuItem(title: "Quit BeQuiet", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Chrome refusing JavaScript from Apple Events is the setup step users
    /// forget; without this it only shows as tabs that never pause. Probed
    /// while the menu opens — never on a timer, and never for a browser the
    /// user switched off, which would prompt for Automation access for nothing.
    private func javaScriptWarning(for controller: any MediaController) -> NSMenuItem? {
        guard let browser = controller as? ChromeController,
              coordinator.settings.enabledControllers.contains(browser.id),
              case .disabled = browser.javaScriptAccess()
        else { return nil }

        let item = deadItem("⚠︎ Allow JavaScript from Apple Events is off in \(browser.displayName)")
        item.indentationLevel = 1
        item.toolTip = browser.javaScriptDisabledHint
        return item
    }

    private func launchAtLoginItem() -> NSMenuItem {
        switch launchAtLogin.state {
        case .unavailable:
            let item = deadItem("Launch at Login")
            item.toolTip = "Available when BeQuiet runs from BeQuiet.app"
            return item

        case .requiresApproval:
            let item = NSMenuItem(
                title: "Launch at Login (approve in System Settings)",
                action: #selector(openLoginItemsSettings),
                keyEquivalent: ""
            )
            item.target = self
            return item

        case .enabled:
            return checkbox("Launch at Login", isOn: true, action: #selector(toggleLaunchAtLogin))

        case .disabled:
            return checkbox("Launch at Login", isOn: false, action: #selector(toggleLaunchAtLogin))
        }
    }

    // MARK: - Items

    private func checkbox(
        _ title: String,
        isOn: Bool,
        action: Selector,
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        item.representedObject = representedObject
        return item
    }

    private func deadItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func presetSubmenu(
        _ title: String,
        presets: [TimeInterval],
        current: TimeInterval,
        action: Selector
    ) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for seconds in presets {
            submenu.addItem(
                checkbox(
                    SecondsLabel.text(seconds),
                    isOn: seconds == current,
                    action: action,
                    representedObject: seconds
                )
            )
        }
        // A value set with `defaults write` must not look like a broken menu.
        if !presets.contains(current) {
            submenu.addItem(
                checkbox(
                    "Custom: \(SecondsLabel.text(current))",
                    isOn: true,
                    action: action,
                    representedObject: current
                )
            )
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        update { $0.isEnabled.toggle() }
    }

    @objc private func toggleController(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? MediaControllerID else { return }

        let isEnabled = !coordinator.settings.enabledControllers.contains(id)
        update { settings in
            if isEnabled {
                settings.enabledControllers.insert(id)
            } else {
                settings.enabledControllers.remove(id)
            }
        }
        // Same reason as the startup warm-up: the Automation prompt should not
        // appear in the middle of a call.
        guard isEnabled, let controller = controllers.first(where: { $0.id == id }) else { return }
        Task { await controller.prepare() }
    }

    @objc private func setDebounce(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        update { $0.debounceSeconds = seconds }
    }

    @objc private func setResumeDelay(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        update { $0.resumeDelaySeconds = seconds }
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(launchAtLogin.state != .enabled)
    }

    @objc private func openLoginItemsSettings() {
        launchAtLogin.openSystemSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// `PauseCoordinator.settings` has a `didSet` that feeds the state machine,
    /// so assigning the whole value is what applies a change.
    private func update(_ change: (inout Settings) -> Void) {
        var settings = coordinator.settings
        change(&settings)
        guard settings != coordinator.settings else { return }

        store.save(settings)
        coordinator.settings = settings
        appLogger.debug("settings changed from the menu")
    }
}
