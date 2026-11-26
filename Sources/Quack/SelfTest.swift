import AVFoundation
import Foundation

/// `Quack --selftest [directory]` checks the synth and the mixer without touching the speakers.
/// With a directory, it also writes one WAV per pack so the sounds can be auditioned.
/// Run it from the project folder, or from inside the built app, so it can find the recordings.
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL")  \(message)")
            if !condition { ok = false }
        }

        let args = CommandLine.arguments
        let outDir = args.firstIndex(of: "--selftest").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }

        let started = Date()
        let loaded = Packs.loadAll()
        print(String(format: "Loaded %d packs in %.0f ms from %@", loaded.count,
                     Date().timeIntervalSince(started) * 1000, Packs.soundsDirectory?.path ?? "(no sounds folder)"))

        for (info, pack) in zip(Packs.all, loaded) {
            guard let pack else {
                check(false, "\(info.name): recordings missing")
                continue
            }
            var peak: Float = 0
            var clean = true
            var longest: Float = 0
            for buffer in pack.press + pack.release {
                longest = max(longest, Float(buffer.count) / (synthSampleRate * buffer.baseRate))
                for s in buffer.samples {
                    if !s.isFinite { clean = false }
                    peak = max(peak, abs(s))
                }
            }
            // The first few milliseconds must already carry sound, or typing would feel late.
            let key = pack.press[KeySlot.row2.rawValue]
            let keyPeak = key.samples.reduce(Float(0)) { max($0, abs($1)) }
            let onset = key.samples.firstIndex { abs($0) > keyPeak * 0.1 } ?? key.count
            let onsetMs = Float(onset) / (synthSampleRate * key.baseRate) * 1000
            check(
                clean && peak >= 0.45 && peak <= 0.85 && pack.press.count == 8 && pack.release.count == 8 && onsetMs < 3,
                String(format: "%-18@ peak %.2f, onset %.1f ms, longest %.0f ms",
                       info.name as NSString, peak, onsetMs, longest * 1000))
        }
        let packs = loaded

        // Mix a few voices offline and make sure sound comes out, then stops.
        let mixer = AudioMixer(offline: true)
        let player = Player(mixer: mixer, packs: packs)
        do {
            player.playSample(pack: 0, up: false, keyCode: 0)   // A, far left
            let left = try mixer.renderOffline(frames: 4800)
            player.playSample(pack: 0, up: false, keyCode: 37)  // L, right side
            let right = try mixer.renderOffline(frames: 4800)
            let silence = try mixer.renderOffline(frames: 48000)

            func rms(_ buffer: AVAudioPCMBuffer, _ channel: Int) -> Float {
                let data = UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
                return (data.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(data.count, 1))).squareRoot()
            }
            check(rms(left, 0) > 0.001, String(format: "mixer produces audio (rms %.4f)", rms(left, 0)))
            check(rms(left, 0) > rms(left, 1) * 1.1, "a left-hand key is louder in the left channel")
            check(rms(right, 1) > rms(right, 0) * 1.1, "a right-hand key is louder in the right channel")
            let tail = UnsafeBufferPointer(start: silence.floatChannelData![0] + 24000, count: 24000)
            check(tail.allSatisfy { $0 == 0 }, "voices end and the mixer returns to silence")

            // Disabled means silent.
            player.update(LiveConfig(active: false))
            player.handle(InputEvent(kind: .keyDown, keyCode: 0))
            let off = try mixer.renderOffline(frames: 4800)
            check(rms(off, 0) == 0, "no sound while disabled")

            // Enabled: a real key event produces sound and is counted once.
            player.update(LiveConfig(active: true))
            player.handle(InputEvent(kind: .keyDown, keyCode: 0))
            player.handle(InputEvent(kind: .keyDown, keyCode: 0, isRepeat: true))
            let on = try mixer.renderOffline(frames: 4800)
            check(rms(on, 0) > 0.001, "a key press plays while enabled")
            check(player.drainKeyCount() == 1, "held-key repeats are not counted or played")
        } catch {
            check(false, "offline render failed: \(error.localizedDescription)")
        }

        if let outDir {
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(synthSampleRate), channels: 1)!
            for (info, loadedPack) in zip(Packs.all, packs) {
                guard let pack = loadedPack else { continue }
                // two keys and a space bar, each pressed then released
                let parts = [
                    pack.press[2], pack.release[2], pack.press[1], pack.release[1],
                    pack.press[KeySlot.space.rawValue], pack.release[KeySlot.space.rawValue],
                ]
                let gap = Int(synthSampleRate * 0.14)
                let total = parts.count * gap + Int(synthSampleRate * 0.4)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else { continue }
                buffer.frameLength = AVAudioFrameCount(total)
                let dst = buffer.floatChannelData![0]
                for i in 0..<total { dst[i] = 0 }
                for (n, part) in parts.enumerated() {
                    for i in 0..<part.count where n * gap + i < total { dst[n * gap + i] += part.data[i] }
                }
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(info.id).wav")
                do {
                    let file = try AVAudioFile(forWriting: url, settings: format.settings)
                    try file.write(from: buffer)
                } catch {
                    check(false, "could not write \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            print("Wrote samples to \(outDir)")
        }

        print("Input Monitoring granted to this process: \(KeyTap.hasPermission)")
        print(ok ? "All checks passed" : "Some checks failed")
        return ok
    }
}
