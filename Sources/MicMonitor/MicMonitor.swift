import CoreAudio
import Darwin
import Foundation

/// Observes microphone activity through CoreAudio without requesting microphone
/// permission: only device and process state is read, never audio.
///
/// `@unchecked Sendable` because all mutable state is confined to `queue`, which
/// is also the queue CoreAudio delivers property notifications on — a
/// confinement the compiler cannot verify.
public final class MicMonitor: @unchecked Sendable {
    private typealias ListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

    private struct ListenerKey: Hashable {
        let objectID: AudioObjectID
        let property: AudioProperty
    }

    private let queue = DispatchQueue(label: "cz.nymsa.BeQuiet.mic")
    private let ownPID = getpid()
    private let pollInterval: TimeInterval

    private var listeners: [ListenerKey: ListenerBlock] = [:]
    private var devices: [AudioObjectID: AudioDeviceInfo] = [:]
    private var processes: [AudioObjectID: AudioProcessInfo] = [:]
    private var ignoredKeys: Set<String>
    private var processListUnavailable = false
    private var micActive = false
    private var deviceLevelActive = false
    private var continuation: AsyncStream<MicEvent>.Continuation?
    private var pollTimer: DispatchSourceTimer?
    private var isRunning = false
    private var session: UInt64 = 0

    /// `pollInterval` bounds how late an unnotified process transition is
    /// noticed; see `updatePolling()`.
    public init(pollInterval: TimeInterval = 1, ignoredProcesses: Set<String> = []) {
        self.pollInterval = pollInterval
        ignoredKeys = ignoredProcesses
    }

    /// Processes that never count as microphone activity, identified by
    /// `AudioProcessInfo.identityKey`. Assigning re-evaluates the aggregates
    /// immediately, so un-ignoring a process that is holding the microphone
    /// makes the microphone active at once, and ignoring the last active one
    /// makes it idle.
    public var ignoredProcesses: Set<String> {
        get { queue.sync { ignoredKeys } }
        set {
            queue.sync {
                guard newValue != ignoredKeys else { return }
                ignoredKeys = newValue
                guard isRunning else { return }
                recomputeAggregates()
            }
        }
    }

    /// Starts observing and returns the event stream. The current state is taken
    /// as the baseline, so no activity event is emitted for it — read it with
    /// `snapshot()`.
    ///
    /// Calling `start()` again tears the previous session down and finishes its
    /// stream; the newly returned stream is the only live one.
    public func start() -> AsyncStream<MicEvent> {
        let (stream, continuation) = AsyncStream<MicEvent>.makeStream(of: MicEvent.self)

        let session = queue.sync { () -> UInt64 in
            teardown()
            self.session += 1
            self.continuation = continuation
            isRunning = true

            devices = scanInputDevices()
            let scan = scanProcesses()
            processes = scan.processes
            processListUnavailable = !scan.isAvailable

            for id in devices.keys { addDeviceListener(id) }
            for id in processes.keys { addProcessListeners(id) }
            addListener(.deviceList, on: AudioObject.system) { [weak self] in
                self?.handleDeviceListChanged()
            }
            addListener(.processObjectList, on: AudioObject.system) { [weak self] in
                self?.handleProcessListChanged()
            }

            let baseline = makeSnapshot()
            micActive = baseline.micActive
            deviceLevelActive = baseline.deviceLevelActive
            updatePolling()
            return self.session
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            // Asynchronously, because `finish()` may be called from inside `queue`.
            queue.async { self.teardown(ifSessionIs: session) }
        }

        return stream
    }

    public func stop() {
        queue.sync { teardown() }
    }

    /// Every audio device on the system, including output-only ones the monitor
    /// does not track. For diagnostics: "where is the music actually going".
    public static func allDevices() -> [AudioDeviceInfo] {
        guard let ids = AudioObject.values(.deviceList, of: AudioObject.system, as: AudioObjectID.self) else {
            return []
        }
        return ids.compactMap(makeDeviceInfo).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Synchronous point-in-time state. While observing, this is the cached state
    /// maintained by the listeners; otherwise CoreAudio is scanned on the spot.
    public func snapshot() -> MicSnapshot {
        queue.sync {
            guard isRunning else {
                let scan = scanProcesses()
                return Self.makeSnapshot(
                    devices: scanInputDevices(),
                    processes: scan.processes,
                    usesDeviceLevelFallback: !scan.isAvailable,
                    ignoredProcesses: ignoredKeys
                )
            }
            return makeSnapshot()
        }
    }

    // MARK: - Notification handling (always on `queue`)

    private func handleDeviceListChanged() {
        guard isRunning else { return }
        let next = scanInputDevices()
        let addedIDs = Set(next.keys).subtracting(devices.keys)
        let removedIDs = Set(devices.keys).subtracting(next.keys)

        for id in removedIDs { removeDeviceListener(id) }
        for id in addedIDs { addDeviceListener(id) }

        let added = addedIDs.compactMap { next[$0] }
        let removed = removedIDs.compactMap { devices[$0] }
        devices = next

        if !added.isEmpty || !removed.isEmpty {
            emit(.deviceListChanged(snapshot: makeSnapshot(), added: added, removed: removed))
        }
        recomputeAggregates()
    }

    private func handleDeviceRunningChanged(_ id: AudioObjectID) {
        guard isRunning, let previous = devices[id], let updated = Self.makeDeviceInfo(id), updated != previous else {
            return
        }
        devices[id] = updated
        emit(.deviceRunningChanged(updated))
        // A device changing its running state means some process changed its IO,
        // and the per-process flags are not reliably notified — re-read them.
        refreshProcessStates()
        recomputeAggregates()
    }

    private func refreshProcessStates() {
        for (id, previous) in processes {
            guard let updated = makeProcessInfo(id), updated != previous else { continue }
            processes[id] = updated
            emit(.processRunningChanged(updated))
        }
    }

    private func handleProcessListChanged() {
        guard isRunning else { return }
        let scan = scanProcesses()
        processListUnavailable = !scan.isAvailable
        let next = scan.processes
        let addedIDs = Set(next.keys).subtracting(processes.keys)
        let removedIDs = Set(processes.keys).subtracting(next.keys)

        for id in removedIDs { removeProcessListeners(id) }
        for id in addedIDs { addProcessListeners(id) }
        processes = next

        if !addedIDs.isEmpty || !removedIDs.isEmpty {
            emit(.processListChanged(makeSnapshot()))
        }
        recomputeAggregates()
    }

    private func handleProcessRunningChanged(_ id: AudioObjectID) {
        guard isRunning, let previous = processes[id], let updated = makeProcessInfo(id), updated != previous else {
            return
        }
        processes[id] = updated
        emit(.processRunningChanged(updated))
        recomputeAggregates()
    }

    private func recomputeAggregates() {
        let snapshot = makeSnapshot()

        if snapshot.deviceLevelActive != deviceLevelActive {
            deviceLevelActive = snapshot.deviceLevelActive
            emit(.deviceLevelActivityChanged(isActive: deviceLevelActive))
        }

        if snapshot.micActive != micActive {
            micActive = snapshot.micActive
            emit(.micActivityChanged(
                isActive: micActive,
                reason: snapshot.activityReason,
                snapshot: snapshot
            ))
        }

        updatePolling()
    }

    /// Process running flags are not notified when a process that already runs
    /// output starts or stops input, and a bidirectional device that is already
    /// running for output does not notify either. While any input-capable device
    /// is running the flags are therefore re-read periodically; when no such
    /// device runs, no process can be capturing and the timer is idle.
    private func updatePolling() {
        let shouldPoll = isRunning && deviceLevelActive && !processListUnavailable
        switch (shouldPoll, pollTimer) {
        case (true, nil):
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + pollInterval,
                repeating: pollInterval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in
                guard let self, isRunning else { return }
                refreshProcessStates()
                recomputeAggregates()
            }
            timer.resume()
            pollTimer = timer
        case let (false, timer?):
            timer.cancel()
            pollTimer = nil
        default:
            break
        }
    }

    private func emit(_ event: MicEvent) {
        continuation?.yield(event)
    }

    // MARK: - Scanning

    private func scanInputDevices() -> [AudioObjectID: AudioDeviceInfo] {
        guard let ids = AudioObject.values(.deviceList, of: AudioObject.system, as: AudioObjectID.self) else {
            micLogger.error("device list unavailable")
            return [:]
        }
        var result: [AudioObjectID: AudioDeviceInfo] = [:]
        for id in ids {
            guard let info = Self.makeDeviceInfo(id), info.hasInput else { continue }
            result[id] = info
        }
        return result
    }

    private static func makeDeviceInfo(_ id: AudioObjectID) -> AudioDeviceInfo? {
        let hasInput = (AudioObject.dataSize(.inputStreams, of: id) ?? 0) > 0
        let hasOutput = (AudioObject.dataSize(.outputStreams, of: id) ?? 0) > 0
        guard hasInput || hasOutput else { return nil }

        let transport = AudioObject.value(.transportType, of: id) ?? kAudioDeviceTransportTypeUnknown
        return AudioDeviceInfo(
            id: id,
            uid: AudioObject.string(.deviceUID, of: id) ?? "",
            name: AudioObject.string(.objectName, of: id) ?? "Unnamed device #\(id)",
            transport: AudioTransport.name(for: transport),
            hasInput: hasInput,
            hasOutput: hasOutput,
            isRunningSomewhere: AudioObject.flag(.deviceIsRunningSomewhere, of: id) ?? false
        )
    }

    private func scanProcesses() -> (processes: [AudioObjectID: AudioProcessInfo], isAvailable: Bool) {
        guard let ids = AudioObject.values(.processObjectList, of: AudioObject.system, as: AudioObjectID.self) else {
            micLogger.error("process object list unavailable, using device-level fallback")
            return ([:], false)
        }
        var result: [AudioObjectID: AudioProcessInfo] = [:]
        for id in ids {
            guard let info = makeProcessInfo(id), info.pid != ownPID else { continue }
            result[id] = info
        }
        return (result, true)
    }

    private func makeProcessInfo(_ id: AudioObjectID) -> AudioProcessInfo? {
        guard let pid = AudioObject.value(.processPID, of: id, as: pid_t.self) else { return nil }
        return AudioProcessInfo(
            id: id,
            pid: pid,
            bundleID: AudioObject.string(.processBundleID, of: id),
            executableName: Self.executableName(of: pid),
            isRunningInput: AudioObject.flag(.processIsRunningInput, of: id) ?? false,
            isRunningOutput: AudioObject.flag(.processIsRunningOutput, of: id) ?? false,
            inputDeviceIDs: AudioObject.values(.processInputDevices, of: id, as: AudioObjectID.self) ?? []
        )
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` is a macro Swift does not import, so its
    /// definition (`4 * MAXPATHLEN`) is spelled out here.
    private static let executablePathCapacity = 4 * Int(MAXPATHLEN)

    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: executablePathCapacity)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
    }

    private func makeSnapshot() -> MicSnapshot {
        Self.makeSnapshot(
            devices: devices,
            processes: processes,
            usesDeviceLevelFallback: processListUnavailable,
            ignoredProcesses: ignoredKeys
        )
    }

    private static func makeSnapshot(
        devices: [AudioObjectID: AudioDeviceInfo],
        processes: [AudioObjectID: AudioProcessInfo],
        usesDeviceLevelFallback: Bool,
        ignoredProcesses: Set<String>
    ) -> MicSnapshot {
        MicSnapshot(
            devices: devices.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            processes: processes.values.sorted { $0.pid < $1.pid },
            usesDeviceLevelFallback: usesDeviceLevelFallback,
            ignoredProcesses: ignoredProcesses
        )
    }

    // MARK: - Listeners

    private func addDeviceListener(_ id: AudioObjectID) {
        addListener(.deviceIsRunningSomewhere, on: id) { [weak self] in
            self?.handleDeviceRunningChanged(id)
        }
    }

    private func removeDeviceListener(_ id: AudioObjectID) {
        removeListener(.deviceIsRunningSomewhere, on: id)
    }

    /// A process object is published with all running flags still 0 and
    /// `kAudioProcessPropertyIsRunningInput`/`Output` were measured not to notify,
    /// so `kAudioProcessPropertyIsRunning` — which does — carries the transition.
    /// All three are observed and every one of them re-reads the full state.
    private static let processRunningProperties: [AudioProperty] = [
        .processIsRunning,
        .processIsRunningInput,
        .processIsRunningOutput,
    ]

    private func addProcessListeners(_ id: AudioObjectID) {
        for property in Self.processRunningProperties {
            addListener(property, on: id) { [weak self] in
                self?.handleProcessRunningChanged(id)
            }
        }
    }

    private func removeProcessListeners(_ id: AudioObjectID) {
        for property in Self.processRunningProperties {
            removeListener(property, on: id)
        }
    }

    private func addListener(
        _ property: AudioProperty,
        on objectID: AudioObjectID,
        handler: @escaping @Sendable () -> Void
    ) {
        let key = ListenerKey(objectID: objectID, property: property)
        guard listeners[key] == nil else { return }

        // Stored as a block so `remove` gets the very same block object back.
        let block: ListenerBlock = { _, _ in handler() }
        var address = property.address
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == noErr else {
            micLogger.error(
                "add listener \(property.label, privacy: .public) on object \(objectID) failed: \(status)"
            )
            return
        }
        listeners[key] = block
    }

    private func removeListener(_ property: AudioProperty, on objectID: AudioObjectID) {
        let key = ListenerKey(objectID: objectID, property: property)
        guard let block = listeners.removeValue(forKey: key) else { return }

        var address = property.address
        let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        if status != noErr {
            micLogger.debug(
                "remove listener \(property.label, privacy: .public) on object \(objectID) failed: \(status)"
            )
        }
    }

    private func teardown(ifSessionIs session: UInt64) {
        guard self.session == session else { return }
        teardown()
    }

    private func teardown() {
        guard isRunning else { return }
        isRunning = false

        for key in Array(listeners.keys) {
            removeListener(key.property, on: key.objectID)
        }
        devices = [:]
        processes = [:]
        processListUnavailable = false
        micActive = false
        deviceLevelActive = false
        updatePolling()

        // Detach before finishing: `finish()` runs `onTermination` synchronously.
        let finishing = continuation
        continuation = nil
        finishing?.finish()
    }
}
