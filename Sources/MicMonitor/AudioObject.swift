import CoreAudio
import Foundation
import os

let micLogger = Logger(subsystem: "cz.nymsa.BeQuiet", category: "mic")

/// A CoreAudio property address, wrapped so it can be used as a dictionary key
/// and logged without repeating the scope/element boilerplate at every call site.
struct AudioProperty: Hashable {
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement

    init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    var label: String { "\(selector.fourCharCode)/\(scope.fourCharCode)" }
}

extension AudioProperty {
    static let deviceList = AudioProperty(kAudioHardwarePropertyDevices)
    static let processObjectList = AudioProperty(kAudioHardwarePropertyProcessObjectList)

    static let objectName = AudioProperty(kAudioObjectPropertyName)
    static let deviceUID = AudioProperty(kAudioDevicePropertyDeviceUID)
    static let transportType = AudioProperty(kAudioDevicePropertyTransportType)
    static let deviceIsRunningSomewhere = AudioProperty(kAudioDevicePropertyDeviceIsRunningSomewhere)
    static let inputStreams = AudioProperty(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    static let outputStreams = AudioProperty(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)

    static let processPID = AudioProperty(kAudioProcessPropertyPID)
    static let processBundleID = AudioProperty(kAudioProcessPropertyBundleID)
    /// Only this one is observed to actually deliver notifications for process
    /// objects; the input/output flags have to be re-read when it fires.
    static let processIsRunning = AudioProperty(kAudioProcessPropertyIsRunning)
    static let processIsRunningInput = AudioProperty(kAudioProcessPropertyIsRunningInput)
    static let processIsRunningOutput = AudioProperty(kAudioProcessPropertyIsRunningOutput)
    static let processInputDevices = AudioProperty(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
}

/// Reads of CoreAudio properties. Every accessor returns `nil` when the property
/// is absent or the read fails — a failing read is never fatal, the value is
/// simply treated as unknown.
enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func value<T: BitwiseCopyable>(
        _ property: AudioProperty,
        of objectID: AudioObjectID,
        as type: T.Type = T.self
    ) -> T? {
        var address = property.address
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeTemporaryAllocation(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        ) { buffer -> T? in
            let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
            guard status == noErr, size >= UInt32(MemoryLayout<T>.size) else {
                logRead(status, property, objectID)
                return nil
            }
            return buffer.load(as: T.self)
        }
    }

    static func values<T: BitwiseCopyable>(
        _ property: AudioProperty,
        of objectID: AudioObjectID,
        as type: T.Type = T.self
    ) -> [T]? {
        guard let byteCount = dataSize(property, of: objectID) else { return nil }
        let stride = MemoryLayout<T>.stride
        let capacity = Int(byteCount) / stride
        guard capacity > 0 else { return [] }

        var address = property.address
        var size = byteCount
        return withUnsafeTemporaryAllocation(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<T>.alignment
        ) { buffer -> [T]? in
            let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
            guard status == noErr else {
                logRead(status, property, objectID)
                return nil
            }
            let count = min(Int(size) / stride, capacity)
            return (0 ..< count).map { buffer.load(fromByteOffset: $0 * stride, as: T.self) }
        }
    }

    /// CoreAudio hands back a +1 retained CFString, hence `Unmanaged` and
    /// `takeRetainedValue`. Empty strings are reported as `nil`.
    static func string(_ property: AudioProperty, of objectID: AudioObjectID) -> String? {
        var address = property.address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let result else {
            logRead(status, property, objectID)
            return nil
        }
        let string = result.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func flag(_ property: AudioProperty, of objectID: AudioObjectID) -> Bool? {
        guard let raw: UInt32 = value(property, of: objectID) else { return nil }
        return raw != 0
    }

    static func dataSize(_ property: AudioProperty, of objectID: AudioObjectID) -> UInt32? {
        var address = property.address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            logRead(status, property, objectID)
            return nil
        }
        return size
    }

    private static func logRead(_ status: OSStatus, _ property: AudioProperty, _ objectID: AudioObjectID) {
        guard status != noErr else { return }
        micLogger.debug(
            "read \(property.label, privacy: .public) on object \(objectID) failed: \(status)"
        )
    }
}

extension UInt32 {
    /// `'bltn'` for printable four-char codes, `0x…` otherwise.
    var fourCharCode: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: self >> UInt32($0)) }
        guard bytes.allSatisfy({ (0x20 ... 0x7E).contains($0) }) else {
            return String(format: "0x%08x", self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum AudioTransport {
    static func name(for raw: UInt32) -> String {
        switch raw {
        case kAudioDeviceTransportTypeUnknown: "unknown"
        case kAudioDeviceTransportTypeBuiltIn: "builtin"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeAutoAggregate: "auto-aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypePCI: "pci"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeFireWire: "firewire"
        case kAudioDeviceTransportTypeBluetooth: "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "bluetooth-le"
        case kAudioDeviceTransportTypeHDMI: "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: "displayport"
        case kAudioDeviceTransportTypeAirPlay: "airplay"
        case kAudioDeviceTransportTypeAVB: "avb"
        case kAudioDeviceTransportTypeThunderbolt: "thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired: "continuity-wired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: "continuity-wireless"
        default: "unknown(\(raw.fourCharCode))"
        }
    }
}
