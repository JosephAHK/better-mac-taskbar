import AudioToolbox
import CoreAudio
import Foundation

/// Default output device volume / mute via CoreAudio.
enum VolumeService {
    /// 0…1 linear volume for the default output device.
    static var volume: Float {
        get {
            guard let device = defaultOutputDeviceID() else { return 0 }
            return getFloat(device: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume) ?? 0
        }
        set {
            guard let device = defaultOutputDeviceID() else { return }
            let clamped = max(0, min(1, newValue))
            setFloat(device: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, value: clamped)
            if clamped > 0.001, isMuted {
                isMuted = false
            }
        }
    }

    static var isMuted: Bool {
        get {
            guard let device = defaultOutputDeviceID() else { return false }
            guard let muted = getUInt32(device: device, selector: kAudioDevicePropertyMute) else { return false }
            return muted != 0
        }
        set {
            guard let device = defaultOutputDeviceID() else { return }
            setUInt32(device: device, selector: kAudioDevicePropertyMute, value: newValue ? 1 : 0)
        }
    }

    static func toggleMute() {
        isMuted.toggle()
    }

    /// SF Symbol name reflecting current mute / level.
    static func speakerSymbolName() -> String {
        if isMuted || volume < 0.01 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.wave.1.fill" }
        if volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func getFloat(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func setFloat(device: AudioDeviceID, selector: AudioObjectPropertySelector, value: Float) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        var writable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else { return }
        var value = value
        let size = UInt32(MemoryLayout<Float>.size)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    private static func getUInt32(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func setUInt32(device: AudioDeviceID, selector: AudioObjectPropertySelector, value: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        var writable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else { return }
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
}
