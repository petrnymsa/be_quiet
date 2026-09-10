import MicMonitor

extension MicSnapshot {
    /// The one line that says whether the microphone counts as active and why;
    /// printed by `watch` and by `run`.
    var aggregatesLine: String {
        let fallback = usesDeviceLevelFallback ? "  fallback=1" : ""
        return "Aggregates: process=\(flag(processLevelActive)) device=\(flag(deviceLevelActive))\(fallback)"
            + "  → MIC \(micActive ? "ACTIVE" : "INACTIVE") (\(activityReason))"
    }

    var activeProcessNames: String {
        activeProcesses.map(\.displayName).joined(separator: ", ")
    }
}
