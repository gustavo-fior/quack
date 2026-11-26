import AVFoundation
import CoreAudio
import os

private let maxVoices = 32

private struct Voice {
    var data: UnsafePointer<Float>?
    var count: Int = 0
    var position: Double = 0
    var rate: Double = 1
    var gainL: Float = 0
    var gainR: Float = 0
    var lpCoef: Float = 1
    var hpGain: Float = 1
    var lpState: Float = 0
    /// Host time of the trigger, cleared once the voice first reaches the output.
    var triggerHost: UInt64 = 0
}

/// State shared between the audio thread and whoever triggers sounds.
final class MixCore {
    fileprivate let voices: UnsafeMutablePointer<Voice>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var running = false
    private var lastTrigger: UInt64 = 0
    private(set) var framesRendered: UInt64 = 0

    // Latency log: for each voice, host ticks from trigger to the render call that first
    // mixed it, and to the time that audio is due at the device.
    private let latencyCapacity = 2048
    private let latencyToRender: UnsafeMutablePointer<UInt64>
    private let latencyToOutput: UnsafeMutablePointer<UInt64>
    private var latencyCount = 0

    func drainLatencies() -> [(toRender: UInt64, toOutput: UInt64)] {
        os_unfair_lock_lock(lock)
        let out = (0..<latencyCount).map { (latencyToRender[$0], latencyToOutput[$0]) }
        latencyCount = 0
        os_unfair_lock_unlock(lock)
        return out
    }

    init() {
        latencyToRender = .allocate(capacity: latencyCapacity)
        latencyToOutput = .allocate(capacity: latencyCapacity)
        voices = .allocate(capacity: maxVoices)
        voices.initialize(repeating: Voice(), count: maxVoices)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    /// Adds a voice. Returns false when the engine is stopped and needs waking.
    func add(_ buffer: SampleBuffer, rate: Float, gain: Float, pan: Float, tone: Float) -> Bool {
        let angle = (min(max(pan, -1), 1) + 1) * Float.pi / 4
        var voice = Voice()
        voice.data = UnsafePointer(buffer.data)
        voice.count = buffer.count
        voice.rate = Double(min(max(rate, 0.25), 4))
        voice.gainL = gain * cos(angle) * 1.4142
        voice.gainR = gain * sin(angle) * 1.4142
        if tone < 0 {
            // Darker: sweep a low-pass from 20 kHz down to 900 Hz.
            let cutoff = 20_000 * pow(0.045, -tone)
            voice.lpCoef = 1 - exp(-2 * Float.pi * cutoff / synthSampleRate)
            voice.hpGain = 0
        } else {
            // Brighter: lift everything above roughly 2.5 kHz.
            voice.lpCoef = 1 - exp(-2 * Float.pi * 2500 / synthSampleRate)
            voice.hpGain = 1 + tone * 1.6
        }

        os_unfair_lock_lock(lock)
        var slot = 0
        var furthest = -1.0
        for i in 0..<maxVoices {
            if voices[i].data == nil {
                slot = i
                break
            }
            // No free slot: steal the voice that is closest to finishing.
            let progress = voices[i].position / Double(max(voices[i].count, 1))
            if progress > furthest {
                furthest = progress
                slot = i
            }
        }
        voice.triggerHost = mach_absolute_time()
        voices[slot] = voice
        lastTrigger = DispatchTime.now().uptimeNanoseconds
        let isRunning = running
        os_unfair_lock_unlock(lock)
        return isRunning
    }

    /// Marks activity without playing anything. Returns whether the engine is running.
    func touch() -> Bool {
        os_unfair_lock_lock(lock)
        lastTrigger = DispatchTime.now().uptimeNanoseconds
        let isRunning = running
        os_unfair_lock_unlock(lock)
        return isRunning
    }

    func setRunning(_ value: Bool) {
        os_unfair_lock_lock(lock)
        running = value
        if !value {
            for i in 0..<maxVoices { voices[i].data = nil }
        }
        os_unfair_lock_unlock(lock)
    }

    /// Seconds since the last trigger, and whether anything is still sounding.
    func idleState() -> (seconds: Double, sounding: Bool) {
        os_unfair_lock_lock(lock)
        let last = lastTrigger
        var sounding = false
        for i in 0..<maxVoices where voices[i].data != nil { sounding = true }
        os_unfair_lock_unlock(lock)
        let now = DispatchTime.now().uptimeNanoseconds
        return (Double(now &- last) / 1e9, sounding)
    }

    func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer, outputHost: UInt64 = 0) {
        guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        for n in 0..<frames {
            left[n] = 0
            right?[n] = 0
        }

        os_unfair_lock_lock(lock)
        for v in 0..<maxVoices {
            guard let data = voices[v].data else { continue }
            var voice = voices[v]
            if voice.triggerHost != 0 {
                if latencyCount < latencyCapacity {
                    latencyToRender[latencyCount] = mach_absolute_time() &- voice.triggerHost
                    latencyToOutput[latencyCount] = outputHost > voice.triggerHost ? outputHost - voice.triggerHost : 0
                    latencyCount += 1
                }
                voice.triggerHost = 0
            }
            let last = voice.count - 1
            var finished = false
            for n in 0..<frames {
                let i = Int(voice.position)
                if i >= last {
                    finished = true
                    break
                }
                let frac = Float(voice.position - Double(i))
                let dry = data[i] + (data[i + 1] - data[i]) * frac
                voice.lpState += voice.lpCoef * (dry - voice.lpState)
                let s = voice.lpState + voice.hpGain * (dry - voice.lpState)
                left[n] += s * voice.gainL
                right?[n] += s * voice.gainR
                voice.position += voice.rate
            }
            if finished { voice.data = nil }
            voices[v] = voice
        }
        framesRendered &+= UInt64(frames)
        os_unfair_lock_unlock(lock)

        // Soft limit so a burst of overlapping keys never clips harshly.
        for n in 0..<frames {
            left[n] = tanhf(left[n])
            if let right { right[n] = tanhf(right[n]) }
        }
    }
}

/// Owns the audio engine. Sounds are mixed by hand in a source node, which keeps
/// the path from key press to speaker as short as the hardware allows.
final class AudioMixer {
    let core = MixCore()
    private let engine = AVAudioEngine()
    private let control = DispatchQueue(label: "quack.audio.control", qos: .userInteractive)
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(synthSampleRate), channels: 2)!
    private var running = false
    private var deviceUID: String?
    private var lastStart = Date.distantPast
    private var idleTimer: DispatchSourceTimer?
    private let offline: Bool

    /// The engine is paused after this long without input, so Quack never keeps the Mac or
    /// the headphones awake. Restarting it is the slowest thing Quack does (10-60 ms), so the
    /// pause is long enough that ordinary gaps in typing don't hit it.
    private let idleSeconds = 30.0

    /// Requested IO buffer. Each key waits half a buffer on average and a full one at worst,
    /// so this is kept small; devices that can't go this low (Bluetooth) use their own minimum.
    static let bufferFrames: UInt32 = 32

    init(offline: Bool = false) {
        self.offline = offline
        let core = self.core
        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList -> OSStatus in
            core.render(
                frames: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(bufferList),
                outputHost: timestamp.pointee.mHostTime)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        if offline {
            try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            return
        }

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.control.async { self?.restartAfterConfigChange() }
        }
        AudioDevices.onDefaultOutputChange { [weak self] in
            self?.control.async { self?.restart() }
        }

        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in self?.pauseIfIdle() }
        timer.resume()
        idleTimer = timer
    }

    func trigger(_ buffer: SampleBuffer, rate: Float, gain: Float, pan: Float, tone: Float) {
        let isRunning = core.add(buffer, rate: rate, gain: gain, pan: pan, tone: tone)
        if !isRunning && !offline {
            control.async { self.startIfNeeded() }
        }
    }

    /// Starts the engine ahead of the next key, and counts as activity for the idle pause.
    func warm() {
        if !core.touch() && !offline {
            control.async { self.startIfNeeded() }
        }
    }

    /// nil follows the system default output.
    func setOutputDevice(uid: String?) {
        control.async {
            guard self.deviceUID != uid else { return }
            self.deviceUID = uid
            self.restart()
        }
    }

    /// Timing figures for the device in use, read while the engine runs.
    func outputTiming() -> AudioDevices.OutputTiming? {
        control.sync {
            (deviceUID.flatMap(AudioDevices.deviceID(forUID:)) ?? AudioDevices.defaultOutputDevice()).map(AudioDevices.timing)
        }
    }

    /// Stops the engine and waits for it, so a benchmark can time a cold start.
    func stopNow() {
        control.sync { self.stop() }
    }

    /// Offline rendering, used by the self test.
    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if !engine.isRunning {
            try engine.start()
            core.setRunning(true)
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        var remaining = frames
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while remaining > 0 {
            let count = min(remaining, engine.manualRenderingMaximumFrameCount)
            _ = try engine.renderOffline(count, to: chunk)
            for channel in 0..<Int(buffer.format.channelCount) {
                let dst = buffer.floatChannelData![channel] + Int(buffer.frameLength)
                dst.update(from: chunk.floatChannelData![channel], count: Int(chunk.frameLength))
            }
            buffer.frameLength += chunk.frameLength
            remaining -= count
        }
        return buffer
    }

    // MARK: - Engine control (always on `control`)

    private func startIfNeeded() {
        guard !running else { return }
        configureOutput()
        do {
            try engine.start()
            running = true
            lastStart = Date()
            core.setRunning(true)
            NSLog("Quack: audio engine started (%.0f Hz output)", engine.outputNode.outputFormat(forBus: 0).sampleRate)
        } catch {
            NSLog("Quack: audio engine failed to start: \(error.localizedDescription)")
            core.setRunning(false)
        }
    }

    private func stop() {
        guard running else { return }
        engine.stop()
        running = false
        core.setRunning(false)
    }

    private func restart() {
        let wasRunning = running
        stop()
        if wasRunning { startIfNeeded() }
    }

    private func restartAfterConfigChange() {
        // Setting the output device ourselves also posts this notification.
        guard Date().timeIntervalSince(lastStart) > 0.5 else { return }
        restart()
    }

    private func pauseIfIdle() {
        guard running else { return }
        let idle = core.idleState()
        if idle.seconds > idleSeconds && !idle.sounding {
            stop()
            NSLog("Quack: audio engine paused after idling")
        }
    }

    private func configureOutput() {
        guard let unit = engine.outputNode.audioUnit else { return }
        let wanted = deviceUID.flatMap(AudioDevices.deviceID(forUID:)) ?? AudioDevices.defaultOutputDevice()
        if var device = wanted {
            var current = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
            if current != device {
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
        }
        // A small hardware buffer is the main thing that keeps latency down. It has to be set
        // on the device itself; setting it on the engine's output unit doesn't stick.
        if let device = wanted { AudioDevices.setBufferSize(device, frames: Self.bufferFrames) }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    }
}
