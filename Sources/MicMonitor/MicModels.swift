import CoreAudio
import Foundation

public struct AudioDeviceInfo: Sendable, Hashable, Identifiable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public let isRunningSomewhere: Bool

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        transport: String,
        hasInput: Bool,
        hasOutput: Bool,
        isRunningSomewhere: Bool
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.isRunningSomewhere = isRunningSomewhere
    }

    public var ioDescription: String {
        switch (hasInput, hasOutput) {
        case (true, true): "in+out"
        case (true, false): "in"
        case (false, true): "out"
        case (false, false): "none"
        }
    }
}

public struct AudioProcessInfo: Sendable, Hashable, Identifiable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
    public let inputDeviceIDs: [AudioObjectID]

    public init(
        id: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        isRunningInput: Bool,
        isRunningOutput: Bool,
        inputDeviceIDs: [AudioObjectID]
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
        self.inputDeviceIDs = inputDeviceIDs
    }

    public var hasAudioIO: Bool { isRunningInput || isRunningOutput }

    /// Bundle IDs are missing for daemons and command line tools.
    public var displayName: String { bundleID ?? "<pid \(pid)>" }
}

public struct MicSnapshot: Sendable, Hashable {
    /// Input-capable devices only, sorted by name.
    public let devices: [AudioDeviceInfo]
    /// Every audio process object except our own, sorted by pid.
    public let processes: [AudioProcessInfo]
    /// True when `kAudioHardwarePropertyProcessObjectList` could not be read and
    /// `micActive` therefore falls back to the device-level aggregate.
    public let usesDeviceLevelFallback: Bool

    public init(
        devices: [AudioDeviceInfo],
        processes: [AudioProcessInfo],
        usesDeviceLevelFallback: Bool
    ) {
        self.devices = devices
        self.processes = processes
        self.usesDeviceLevelFallback = usesDeviceLevelFallback
    }

    public var deviceLevelActive: Bool { devices.contains(where: \.isRunningSomewhere) }

    public var processLevelActive: Bool { processes.contains(where: \.isRunningInput) }

    public var micActive: Bool { usesDeviceLevelFallback ? deviceLevelActive : processLevelActive }

    public var activeProcesses: [AudioProcessInfo] { processes.filter(\.isRunningInput) }

    public var processesWithAudioIO: [AudioProcessInfo] { processes.filter(\.hasAudioIO) }

    public var activityReason: String {
        guard !usesDeviceLevelFallback else {
            guard let device = devices.first(where: \.isRunningSomewhere) else {
                return "fallback: no input-capable device is running"
            }
            return "fallback: device \(device.name) running"
        }
        guard let process = activeProcesses.first else { return "no process is running input" }
        return "process \(process.displayName) (pid \(process.pid)) started input"
    }

    public func deviceName(for id: AudioObjectID) -> String {
        devices.first { $0.id == id }?.name ?? "#\(id)"
    }
}

public enum MicEvent: Sendable {
    case deviceListChanged(snapshot: MicSnapshot, added: [AudioDeviceInfo], removed: [AudioDeviceInfo])
    case deviceRunningChanged(AudioDeviceInfo)
    case processListChanged(MicSnapshot)
    /// One process changed its input and/or output running flag.
    case processRunningChanged(AudioProcessInfo)
    case micActivityChanged(isActive: Bool, reason: String, snapshot: MicSnapshot)
    /// Reported separately from `micActivityChanged` so both aggregates can be
    /// compared while the truth rule is being validated.
    case deviceLevelActivityChanged(isActive: Bool)
}
