import Foundation
import MediaControl
import Testing

import BeQuietCore

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test("missing keys fall back to the defaults and settings round-trip")
    func roundTrip() throws {
        let suiteName = "cz.nymsa.BeQuiet.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.load() == Settings())
        #expect(store.load().enabledControllers == [.spotify, .appleMusic, .chrome, .safari])
        #expect(store.load().ignoredProcesses == Settings.defaultIgnoredProcesses)

        let settings = Settings(
            isEnabled: false,
            debounceSeconds: 0.5,
            resumeDelaySeconds: 10,
            enabledControllers: [],
            ignoredProcesses: ["com.utmapp.UTM"]
        )
        store.save(settings)
        #expect(store.load() == settings)

        #expect(defaults.object(forKey: "enabled") as? Bool == false)
        #expect(defaults.object(forKey: "debounceSeconds") as? Double == 0.5)
        #expect(defaults.object(forKey: "resumeDelaySeconds") as? Double == 10)
        #expect(defaults.object(forKey: "controller.spotify") as? Bool == false)
        #expect(defaults.object(forKey: "controller.chrome:com.google.Chrome") as? Bool == false)
        #expect(defaults.object(forKey: "controller.safari") as? Bool == false)
        #expect(defaults.object(forKey: "ignoredProcesses") as? [String] == ["com.utmapp.UTM"])
    }

    @Test("an ignore list the user cleared stays cleared")
    func clearedIgnoreList() throws {
        let suiteName = "cz.nymsa.BeQuiet.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        // Missing key: the Android Emulator is ignored out of the box.
        #expect(store.load().ignoredProcesses == Settings.defaultIgnoredProcesses)

        store.save(Settings(ignoredProcesses: []))
        #expect(store.load().ignoredProcesses.isEmpty)

        defaults.removeObject(forKey: "ignoredProcesses")
        #expect(store.load().ignoredProcesses == Settings.defaultIgnoredProcesses)
    }

    @Test("the built-in ignore list applies to a store that already has a saved list")
    func builtInsApplyToASavedList() throws {
        let suiteName = "cz.nymsa.BeQuiet.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.save(Settings(ignoredProcesses: ["com.utmapp.UTM"]))

        let loaded = store.load()
        #expect(loaded.ignoredProcesses == ["com.utmapp.UTM"])
        #expect(loaded.effectiveIgnoredProcesses
            == Settings.builtInIgnoredProcesses.union(["com.utmapp.UTM"]))
        #expect(loaded.effectiveIgnoredProcesses.contains("com.apple.CoreSpeech"))
        // The built-ins are applied, never written back.
        #expect(defaults.stringArray(forKey: "ignoredProcesses") == ["com.utmapp.UTM"])
    }

    @Test("the built-in ignore list survives a cleared ignore list")
    func builtInsSurviveAClearedList() {
        #expect(Settings(ignoredProcesses: []).effectiveIgnoredProcesses
            == Settings.builtInIgnoredProcesses)
    }
}
