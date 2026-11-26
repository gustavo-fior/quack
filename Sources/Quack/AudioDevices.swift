import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func outputDevices() -> [OutputDevice] {
        allDeviceIDs().filter(hasOutput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return OutputDevice(uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { hasOutput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        uint32(system, kAudioHardwarePropertyDefaultOutputDevice).flatMap { $0 == 0 ? nil : $0 }
    }

    private static func uint32(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var addr = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// Asks the device for an IO buffer of about `frames`, within what it supports.
    /// The device may settle on something larger if another app needs it.
    static func setBufferSize(_ device: AudioDeviceID, frames: UInt32) {
        var addr = address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var wanted = frames
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range) == noErr, range.mMaximum > 0 {
            wanted = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }
        var set = address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(device, &set, 0, nil, UInt32(MemoryLayout<UInt32>.size), &wanted)
    }

    struct OutputTiming {
        var name = ""
        var transport = ""
        var sampleRate = 48_000.0
        var bufferFrames = 0
        /// Frames of delay the device and its stream report after the buffer is handed over.
        var deviceLatencyFrames = 0
    }

    static func timing(_ device: AudioDeviceID) -> OutputTiming {
        var out = OutputTiming()
        out.name = string(device, kAudioObjectPropertyName) ?? "?"
        switch uint32(device, kAudioDevicePropertyTransportType) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: out.transport = "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: out.transport = "Bluetooth"
        case kAudioDeviceTransportTypeUSB: out.transport = "USB"
        case kAudioDeviceTransportTypeAirPlay: out.transport = "AirPlay"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: out.transport = "display"
        default: out.transport = "other"
        }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 0 { out.sampleRate = rate }
        out.bufferFrames = Int(uint32(device, kAudioDevicePropertyBufferFrameSize) ?? 0)
        var latency = uint32(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput)
            + uint32(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput)
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var streamSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 {
            var ids = [AudioStreamID](repeating: 0, count: Int(streamSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &streams, 0, nil, &streamSize, &ids) == noErr, let first = ids.first {
                latency += uint32(first, kAudioStreamPropertyLatency) ?? 0
            }
        }
        out.deviceLatencyFrames = Int(latency)
        return out
    }

    static func onDefaultOutputChange(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.global(qos: .userInitiated)) { _, _ in
            handler()
        }
    }

    /// True while any app is capturing from the default microphone, which usually means a call.
    static func microphoneInUse() -> Bool {
        guard let input = uint32(system, kAudioHardwarePropertyDefaultInputDevice), input != 0 else { return false }
        return (uint32(input, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
    }
}
