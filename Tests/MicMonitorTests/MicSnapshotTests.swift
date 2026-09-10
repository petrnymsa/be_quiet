import CoreAudio
import Testing

import MicMonitor

@Suite("MicSnapshot ignore list")
struct MicSnapshotTests {
    private let emulator = makeProcess(
        pid: 10,
        bundleID: nil,
        executableName: "qemu-system-aarch64",
        isRunningInput: true
    )
    private let teams = makeProcess(
        pid: 20,
        bundleID: "com.microsoft.teams2",
        executableName: "MSTeams",
        isRunningInput: true
    )
    private let utm = makeProcess(
        pid: 30,
        bundleID: "com.utmapp.UTM",
        executableName: "UTM",
        isRunningInput: true
    )
    private let spotify = makeProcess(
        pid: 50,
        bundleID: "com.spotify.client",
        executableName: "Spotify",
        isRunningOutput: true
    )

    @Test("an ignored process holding the microphone does not count as activity")
    func ignoredProcessAlone() {
        let snapshot = makeSnapshot(processes: [emulator], ignoredProcesses: ["qemu-system-aarch64"])
        #expect(!snapshot.micActive)
        #expect(!snapshot.processLevelActive)
        #expect(snapshot.activeProcesses.isEmpty)
        #expect(snapshot.ignoredActiveProcesses.map(\.pid) == [emulator.pid])
        #expect(snapshot.activityReason == "no process is running input (ignoring qemu-system-aarch64)")
    }

    @Test("another process holding the microphone still counts")
    func ignoredAndActive() {
        let snapshot = makeSnapshot(
            processes: [emulator, teams],
            ignoredProcesses: ["qemu-system-aarch64"]
        )
        #expect(snapshot.micActive)
        #expect(snapshot.activeProcesses.map(\.pid) == [teams.pid])
        #expect(snapshot.ignoredActiveProcesses.map(\.pid) == [emulator.pid])
        #expect(snapshot.activityReason == "process com.microsoft.teams2 (pid 20) started input")
    }

    @Test("an empty ignore list leaves the behaviour unchanged")
    func emptyIgnoreList() {
        let snapshot = makeSnapshot(processes: [emulator, teams])
        #expect(snapshot.micActive)
        #expect(snapshot.activeProcesses.map(\.pid) == [emulator.pid, teams.pid])
        #expect(snapshot.ignoredActiveProcesses.isEmpty)
        #expect(snapshot.activityReason == "process qemu-system-aarch64 (pid 10) started input")
    }

    @Test("a process that is not running input is unaffected by the ignore list")
    func outputOnlyProcess() {
        let snapshot = makeSnapshot(processes: [spotify], ignoredProcesses: ["com.spotify.client"])
        #expect(!snapshot.micActive)
        #expect(snapshot.activeProcesses.isEmpty)
        #expect(snapshot.ignoredActiveProcesses.isEmpty)
        #expect(snapshot.activityReason == "no process is running input")
    }

    @Test("every ignored process holding the microphone is named")
    func severalIgnoredProcesses() {
        let snapshot = makeSnapshot(
            processes: [emulator, utm],
            ignoredProcesses: ["qemu-system-aarch64", "com.utmapp.UTM"]
        )
        #expect(!snapshot.micActive)
        #expect(
            snapshot.activityReason
                == "no process is running input (ignoring qemu-system-aarch64, com.utmapp.UTM)"
        )
    }

    @Test("the device-level fallback ignores the process ignore list")
    func fallback() {
        let snapshot = MicSnapshot(
            devices: [runningDevice],
            processes: [emulator],
            usesDeviceLevelFallback: true,
            ignoredProcesses: ["qemu-system-aarch64"]
        )
        #expect(snapshot.micActive)
        #expect(snapshot.activityReason == "fallback: device MacBook Pro Microphone running")
    }

    @Test("identity is the bundle ID first, then the executable name")
    func identityKeyPreference() {
        #expect(teams.identityKey == "com.microsoft.teams2")
        #expect(teams.displayName == "com.microsoft.teams2")
        #expect(emulator.identityKey == "qemu-system-aarch64")
        #expect(emulator.displayName == "qemu-system-aarch64")

        let unnamed = makeProcess(pid: 40, bundleID: nil, executableName: nil)
        #expect(unnamed.identityKey == nil)
        #expect(unnamed.displayName == "<pid 40>")
    }

    @Test("a process without an identity is never ignored")
    func processWithoutIdentity() {
        let unnamed = makeProcess(pid: 40, bundleID: nil, executableName: nil, isRunningInput: true)
        let snapshot = makeSnapshot(processes: [unnamed], ignoredProcesses: ["qemu-system-aarch64"])
        #expect(snapshot.micActive)
        #expect(!snapshot.isIgnored(unnamed))
    }
}

// MARK: - Fixtures

private let runningDevice = AudioDeviceInfo(
    id: 1,
    uid: "BuiltInMicrophoneDevice",
    name: "MacBook Pro Microphone",
    transport: "Built-in",
    hasInput: true,
    hasOutput: false,
    isRunningSomewhere: true
)

private func makeProcess(
    pid: pid_t,
    bundleID: String?,
    executableName: String?,
    isRunningInput: Bool = false,
    isRunningOutput: Bool = false
) -> AudioProcessInfo {
    AudioProcessInfo(
        id: AudioObjectID(pid),
        pid: pid,
        bundleID: bundleID,
        executableName: executableName,
        isRunningInput: isRunningInput,
        isRunningOutput: isRunningOutput,
        inputDeviceIDs: []
    )
}

private func makeSnapshot(
    processes: [AudioProcessInfo],
    ignoredProcesses: Set<String> = []
) -> MicSnapshot {
    MicSnapshot(
        devices: [runningDevice],
        processes: processes,
        usesDeviceLevelFallback: false,
        ignoredProcesses: ignoredProcesses
    )
}
