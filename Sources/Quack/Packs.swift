import AVFoundation
import Foundation

/// Immutable PCM data handed to the audio thread. It lives for the life of the process.
final class SampleBuffer {
    let data: UnsafeMutablePointer<Float>
    let count: Int
    /// Playback rate that plays this buffer at its natural pitch on the 48 kHz mixer.
    let baseRate: Float

    init(_ samples: [Float], sampleRate: Float = synthSampleRate) {
        count = samples.count
        baseRate = sampleRate / synthSampleRate
        data = .allocate(capacity: max(samples.count, 1))
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { data.initialize(from: base, count: samples.count) }
        }
    }

    var samples: UnsafeBufferPointer<Float> { UnsafeBufferPointer(start: data, count: count) }
}

/// Which recording a key uses. Real boards sound different row by row, and the wide keys
/// have stabilizers, so each gets its own sample.
enum KeySlot: Int, CaseIterable {
    case row0, row1, row2, row3, row4, space, enter, backspace

    var pressFile: String {
        switch self {
        case .row0: return "GENERIC_R0"
        case .row1: return "GENERIC_R1"
        case .row2: return "GENERIC_R2"
        case .row3: return "GENERIC_R3"
        case .row4: return "GENERIC_R4"
        case .space: return "SPACE"
        case .enter: return "ENTER"
        case .backspace: return "BACKSPACE"
        }
    }

    var releaseFile: String {
        switch self {
        case .space: return "SPACE"
        case .enter: return "ENTER"
        case .backspace: return "BACKSPACE"
        default: return "GENERIC"
        }
    }

    /// Used when a pack has no dedicated recording for a wide key.
    var fallback: KeySlot {
        switch self {
        case .space: return .row4
        case .enter: return .row2
        case .backspace: return .row0
        default: return .row2
        }
    }
}

struct PackInfo: Identifiable {
    enum Kind {
        /// Recordings of a real switch, stored in `Resources/Sounds/<folder>`.
        case recorded(folder: String)
        case duck
    }

    let id: String
    let name: String
    let group: String
    let blurb: String
    let kind: Kind
}

/// Loaded sounds for one pack, indexed by `KeySlot.rawValue`.
struct PackSamples {
    var press: [SampleBuffer]
    var release: [SampleBuffer]
}

enum Packs {
    static let all: [PackInfo] = [
        PackInfo(id: "blackink", name: "Gateron Black Ink", group: "Linear", blurb: "Deep", kind: .recorded(folder: "blackink")),
        PackInfo(id: "redink", name: "Gateron Red Ink", group: "Linear", blurb: "Light", kind: .recorded(folder: "redink")),
        PackInfo(id: "cream", name: "NovelKeys Cream", group: "Linear", blurb: "Creamy", kind: .recorded(folder: "cream")),
        PackInfo(id: "mxblack", name: "Cherry MX Black", group: "Linear", blurb: "Classic", kind: .recorded(folder: "mxblack")),
        PackInfo(id: "alpaca", name: "Alpaca", group: "Linear", blurb: "Smooth", kind: .recorded(folder: "alpaca")),
        PackInfo(id: "turquoise", name: "Turquoise Tealios", group: "Linear", blurb: "Crisp", kind: .recorded(folder: "turquoise")),
        PackInfo(id: "holypanda", name: "Holy Panda", group: "Tactile", blurb: "Thocky", kind: .recorded(folder: "holypanda")),
        PackInfo(id: "mxbrown", name: "Cherry MX Brown", group: "Tactile", blurb: "Gentle", kind: .recorded(folder: "mxbrown")),
        PackInfo(id: "topre", name: "Topre", group: "Tactile", blurb: "Rounded", kind: .recorded(folder: "topre")),
        PackInfo(id: "mxblue", name: "Cherry MX Blue", group: "Clicky", blurb: "Clicky", kind: .recorded(folder: "mxblue")),
        PackInfo(id: "boxnavy", name: "Kailh Box Navy", group: "Clicky", blurb: "Heavy click", kind: .recorded(folder: "boxnavy")),
        PackInfo(id: "bluealps", name: "Alps Blue", group: "Clicky", blurb: "Vintage", kind: .recorded(folder: "bluealps")),
        PackInfo(id: "buckling", name: "Buckling Spring", group: "Clicky", blurb: "Model M", kind: .recorded(folder: "buckling")),
        PackInfo(id: "quack", name: "Duck", group: "Just for fun", blurb: "Not a switch", kind: .duck),
    ]

    static let defaultID = "blackink"

    static func index(of id: String) -> Int {
        all.firstIndex { $0.id == id } ?? 0
    }

    /// The folder of recordings: inside the app bundle, or the project folder when run unbundled.
    static let soundsDirectory: URL? = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Sounds")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Sounds"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("LICENSE.md").path) }
    }()

    /// Decodes a recording to mono float and trims the silence around it. Leading silence
    /// matters most: MP3 padding alone would add around 25 ms of delay to every key.
    static func loadRecording(_ url: URL) -> (samples: [Float], sampleRate: Float)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var samples = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            for i in 0..<frames { samples[i] += channels[c][i] / Float(channelCount) }
        }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return nil }
        let sampleRate = Float(buffer.format.sampleRate)
        // The recordings sit on a noise floor of a few percent, so the key is taken to start
        // where the level first reaches a tenth of its peak.
        let first = samples.firstIndex { abs($0) > peak * 0.1 } ?? 0
        let last = samples.lastIndex { abs($0) > peak * 0.03 } ?? (frames - 1)
        let start = max(0, first - Int(sampleRate * 0.0005))
        let end = min(frames, last + Int(sampleRate * 0.006))
        samples = Array(samples[start..<end])
        // Short fades so the trim points never click.
        let fadeIn = min(samples.count, Int(sampleRate * 0.0005))
        for i in 0..<fadeIn { samples[i] *= Float(i) / Float(fadeIn) }
        let fadeOut = min(samples.count, Int(sampleRate * 0.006))
        for i in 0..<fadeOut { samples[samples.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return (samples, sampleRate)
    }

    private static func loadRecorded(folder: String) -> PackSamples? {
        guard let dir = soundsDirectory?.appendingPathComponent(folder) else { return nil }
        var cache: [String: (samples: [Float], sampleRate: Float)] = [:]
        func load(_ sub: String, _ name: String) -> (samples: [Float], sampleRate: Float)? {
            let key = "\(sub)/\(name)"
            if let hit = cache[key] { return hit }
            let loaded = loadRecording(dir.appendingPathComponent("\(key).mp3"))
            cache[key] = loaded
            return loaded
        }

        var press: [(samples: [Float], sampleRate: Float)] = []
        var release: [(samples: [Float], sampleRate: Float)] = []
        for slot in KeySlot.allCases {
            guard let p = load("press", slot.pressFile) ?? load("press", slot.fallback.pressFile),
                  let r = load("release", slot.releaseFile) ?? load("release", "GENERIC") else { return nil }
            press.append(p)
            release.append(r)
        }

        // Levels differ a lot between recordings, so they are evened out here. Ordinary keys
        // all play at the same peak. Wide keys and releases keep their level relative to the
        // ordinary keys, within limits, so a space bar is louder and a release is softer.
        func peak(_ r: (samples: [Float], sampleRate: Float)) -> Float {
            max(r.samples.reduce(Float(0)) { max($0, abs($1)) }, 0.0001)
        }
        let rowPeaks = press.prefix(5).map(peak).sorted()
        let packGain = 0.5 / rowPeaks[rowPeaks.count / 2]
        func buffer(_ r: (samples: [Float], sampleRate: Float), target: Float) -> SampleBuffer {
            let gain = target / peak(r)
            return SampleBuffer(r.samples.map { $0 * gain }, sampleRate: r.sampleRate)
        }
        let pressBuffers = press.enumerated().map { index, r in
            index < 5 ? buffer(r, target: 0.5) : buffer(r, target: min(max(peak(r) * packGain, 0.5), 0.8))
        }
        let releaseBuffers = release.map { r in
            buffer(r, target: min(max(peak(r) * packGain, 0.15), 0.45))
        }
        return PackSamples(press: pressBuffers, release: releaseBuffers)
    }

    private static func renderDuck() -> PackSamples {
        var rng = RNG(state: 0xD0C5)
        func make(up: Bool) -> [SampleBuffer] {
            KeySlot.allCases.map { slot in
                let size: QuackSize
                switch slot {
                case .space: size = .large
                case .enter, .backspace: size = .medium
                default: size = .regular
                }
                return SampleBuffer(renderQuack(up: up, size: size, rng: &rng))
            }
        }
        return PackSamples(press: make(up: false), release: make(up: true))
    }

    /// Loads every pack. A pack whose recordings are missing comes back nil.
    static func loadAll() -> [PackSamples?] {
        all.map { pack in
            switch pack.kind {
            case .recorded(let folder): return loadRecorded(folder: folder)
            case .duck: return renderDuck()
            }
        }
    }
}
