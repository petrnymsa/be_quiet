import CoreAudio
import Darwin
import Foundation
import MicMonitor

enum WatchCommand {
    static func run() async {
        let monitor = MicMonitor()
        let events = monitor.start()
        let interrupts = Interrupts.install { monitor.stop() }
        defer { interrupts.forEach { $0.cancel() } }

        Output.line("bequiet watch — CoreAudio microphone activity (Ctrl-C to stop)")
        Output.line()

        let initial = monitor.snapshot()
        var deviceNames = names(in: initial)
        printSnapshot(initial)
        Output.line()

        for await event in events {
            switch event {
            case let .deviceListChanged(snapshot, added, removed):
                deviceNames = names(in: snapshot)
                let changes = added.map { "+ \($0.name.quoted)" } + removed.map { "− \($0.name.quoted)" }
                Output.event(
                    "DEVICES",
                    "list changed (\(snapshot.devices.count) input devices): \(changes.joined(separator: "  "))"
                )

            case let .deviceRunningChanged(device):
                Output.event("DEVICE", "\(device.name.quoted) running=\(flag(device.isRunningSomewhere))")

            case let .processListChanged(snapshot):
                deviceNames = names(in: snapshot)
                Output.event(
                    "PROCESSES",
                    "list changed (\(snapshot.processesWithAudioIO.count) with audio IO, "
                        + "\(snapshot.processes.count) total)"
                )

            case let .processRunningChanged(process):
                let inputDevices = process.inputDeviceIDs.map { deviceNames[$0] ?? "#\($0)" }
                Output.event(
                    "PROCESS",
                    "\(process.displayName) pid=\(process.pid) "
                        + "input=\(flag(process.isRunningInput)) output=\(flag(process.isRunningOutput))"
                        + (inputDevices.isEmpty ? "" : "  inputDevices=[\(inputDevices.joined(separator: ", "))]")
                )

            case let .micActivityChanged(isActive, reason, _):
                let status = isActive ? "ACTIVE" : "INACTIVE"
                Output.event("MIC", "\(status.padded(to: 8)) reason: \(reason)")

            case let .deviceLevelActivityChanged(isActive):
                Output.event("DEVICE-LEVEL", "active=\(flag(isActive))")
            }
        }

        Output.line()
        Output.line("watch stopped.")
    }

    // MARK: - Snapshot rendering

    private static func printSnapshot(_ snapshot: MicSnapshot) {
        let devices = snapshot.devices
        Output.line("Input devices (\(devices.count)):")
        let nameWidth = devices.map(\.name.quoted.count).max() ?? 0
        let uidWidth = devices.map(\.uid.count).max() ?? 0
        let transportWidth = devices.map(\.transport.count).max() ?? 0
        for device in devices {
            Output.line(
                "  [\(device.isRunningSomewhere ? "running" : "idle   ")] "
                    + "\(device.name.quoted.padded(to: nameWidth))  "
                    + "uid=\(device.uid.padded(to: uidWidth))  "
                    + "transport=\(device.transport.padded(to: transportWidth))  "
                    + "in/out=\(device.ioDescription)"
            )
        }

        let processes = snapshot.processesWithAudioIO
        Output.line("Processes with audio IO (\(processes.count)):")
        let pidWidth = processes.map { String($0.pid).count }.max() ?? 0
        let bundleWidth = processes.map(\.displayName.count).max() ?? 0
        for process in processes {
            let inputDevices = process.inputDeviceIDs.map { snapshot.deviceName(for: $0) }
            Output.line(
                "  pid \(String(process.pid).padded(to: pidWidth))  "
                    + "\(process.displayName.padded(to: bundleWidth))  "
                    + "input=\(flag(process.isRunningInput)) output=\(flag(process.isRunningOutput))  "
                    + "inputDevices=[\(inputDevices.joined(separator: ", "))]"
            )
        }

        Output.line(snapshot.aggregatesLine)
    }

    private static func names(in snapshot: MicSnapshot) -> [AudioObjectID: String] {
        Dictionary(uniqueKeysWithValues: snapshot.devices.map { ($0.id, $0.name) })
    }
}
