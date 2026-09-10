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

        let settings = Settings(
            isEnabled: false,
            debounceSeconds: 0.5,
            resumeDelaySeconds: 10,
            enabledControllers: []
        )
        store.save(settings)
        #expect(store.load() == settings)

        #expect(defaults.object(forKey: "enabled") as? Bool == false)
        #expect(defaults.object(forKey: "debounceSeconds") as? Double == 0.5)
        #expect(defaults.object(forKey: "resumeDelaySeconds") as? Double == 10)
        #expect(defaults.object(forKey: "controller.spotify") as? Bool == false)
    }
}
