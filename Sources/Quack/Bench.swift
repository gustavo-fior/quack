import CoreGraphics
import Foundation

/// `Quack --bench` measures how long a key press takes to become sound.
///
/// It posts harmless synthetic key events, lets them travel through the real event tap, and
/// plays a key through the player and mixer when each one arrives, timing every stage. The
/// volume is zero, so the run is silent. It needs the same Input Monitoring permission as the
/// app (running it from a terminal that has it works). Without permission to post events,
/// macOS may deliver the synthetic key as a different event; the tap still sees it arrive,
/// which is all the timing needs.
enum Bench {
    private static var timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func ms(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6
    }

    static func summary(_ label: String, _ values: [Double]) {
        guard !values.isEmpty else {
            print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) no samples")
            return
        }
        let sorted = values.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        print(String(
            format: "  %@ median %6.2f   p95 %6.2f   max %6.2f   (n=%d)",
            label.padding(toLength: 34, withPad: " ", startingAt: 0) as NSString,
            pct(0.5), pct(0.95), sorted.last!, sorted.count))
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func run() {
        guard KeyTap.hasPermission else {
            print("This process has no Input Monitoring permission, so the benchmark can't see key events.")
            return
        }
        let mixer = AudioMixer()
        let player = Player(mixer: mixer, packs: Packs.loadAll())
        // Inactive, so real typing during the run doesn't add voices of its own.
        var config = LiveConfig(active: false)
        config.volume = 0
        player.update(config)

        // Stage timings recorded on the tap thread.
        let lock = NSLock()
        var posted: UInt64 = 0
        var tapDelay: [Double] = []
        var handleTime: [Double] = []
        let tap = KeyTap()
        tap.handler = { event in
            let received = mach_absolute_time()
            lock.lock()
            let sent = posted
            posted = 0
            lock.unlock()
            guard sent != 0 else { return }
            player.playSample(pack: 0, up: false, keyCode: 0)
            let done = mach_absolute_time()
            lock.lock()
            tapDelay.append(ms(received &- sent))
            handleTime.append(ms(done &- received))
            lock.unlock()
        }
        guard tap.install() else {
            print("Could not create the event tap.")
            return
        }
        usleep(300_000)

        let source = CGEventSource(stateID: .hidSystemState)
        func press() {
            lock.lock()
            posted = mach_absolute_time()
            lock.unlock()
            CGEvent(keyboardEventSource: source, virtualKey: 90, keyDown: true)?.post(tap: .cghidEventTap)
            usleep(30_000)
            CGEvent(keyboardEventSource: source, virtualKey: 90, keyDown: false)?.post(tap: .cghidEventTap)
        }


        func measure() {
            // Cold: the engine is stopped, as it is after a pause in typing.
            var cold: [Double] = []
            for _ in 0..<6 {
                mixer.stopNow()
                usleep(400_000)
                _ = mixer.core.drainLatencies()
                press()
                usleep(900_000)
                cold += mixer.core.drainLatencies().prefix(1).map { ms($0.toRender) }
            }

            // Warm: the engine is already running, as it is while typing.
            press()
            usleep(500_000)
            _ = mixer.core.drainLatencies()
            lock.lock()
            tapDelay = []
            handleTime = []
            lock.unlock()
            for _ in 0..<60 {
                press()
                usleep(UInt32.random(in: 40_000...90_000))
            }
            usleep(300_000)
            let warm = mixer.core.drainLatencies()
            let timing = mixer.outputTiming()

            // Cost of keeping the engine running with nothing playing.
            let cpuStart = cpuSeconds()
            let wallStart = Date()
            usleep(3_000_000)
            let idleCPU = (cpuSeconds() - cpuStart) / Date().timeIntervalSince(wallStart) * 100

            if let timing {
                print(String(
                    format: "Output: %@ (%@), %.0f Hz, %d-frame buffer (%.1f ms), device latency %.1f ms",
                    timing.name, timing.transport, timing.sampleRate, timing.bufferFrames,
                    Double(timing.bufferFrames) / timing.sampleRate * 1000,
                    Double(timing.deviceLatencyFrames) / timing.sampleRate * 1000))
            }
            print("Milliseconds, per key press:")
            lock.lock()
            summary("event posted -> tap callback", tapDelay)
            summary("tap callback -> voice queued", handleTime)
            lock.unlock()
            summary("voice queued -> mixed (warm)", warm.map { ms($0.toRender) })
            summary("voice queued -> due at device", warm.map { ms($0.toOutput) })
            summary("voice queued -> mixed (cold start)", cold)
            print(String(format: "  idle cost with the engine running   %.2f%% of one core", idleCPU))
        }

        let only = CommandLine.arguments.firstIndex(of: "--device").flatMap {
            CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
        }
        if let only {
            guard let device = AudioDevices.outputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(only) }) else {
                print("No output device matching \(only). Available: \(AudioDevices.outputDevices().map(\.name))")
                return
            }
            mixer.setOutputDevice(uid: device.uid)
        }
        measure()
    }
}
