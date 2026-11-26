import Foundation

// The switch sounds are recordings (see Packs.swift). Only the novelty duck is synthesized here.

let synthSampleRate: Float = 48_000

enum QuackSize {
    case regular, medium, large
}

/// Small seeded generator so each launch renders the same set of sounds.
struct RNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func uni() -> Float { Float(next() >> 40) / Float(1 << 24) }
    /// -1..<1
    mutating func bi() -> Float { uni() * 2 - 1 }
    /// 1 ± amount
    mutating func jitter(_ amount: Float) -> Float { 1 + bi() * amount }
}

struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var z1: Float = 0, z2: Float = 0

    private static func make(_ fc: Float, _ q: Float, _ build: (Float, Float) -> (Float, Float, Float)) -> Biquad {
        let f = min(max(fc, 20), synthSampleRate * 0.45)
        let w0 = 2 * Float.pi * f / synthSampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let (b0, b1, b2) = build(alpha, cosw)
        let a0 = 1 + alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
    }

    static func lowpass(_ fc: Float, q: Float = 0.707) -> Biquad {
        make(fc, q) { _, c in ((1 - c) / 2, 1 - c, (1 - c) / 2) }
    }

    static func highpass(_ fc: Float, q: Float = 0.707) -> Biquad {
        make(fc, q) { _, c in ((1 + c) / 2, -(1 + c), (1 + c) / 2) }
    }

    static func bandpass(_ fc: Float, q: Float) -> Biquad {
        make(fc, q) { a, _ in (a, 0, -a) }
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

private func finish(_ samples: inout [Float], lowpass: Float, highpass: Float, peak: Float) {
    var hp = Biquad.highpass(highpass)
    var lp1 = Biquad.lowpass(lowpass)
    var lp2 = Biquad.lowpass(lowpass)
    var maxAbs: Float = 0
    for i in samples.indices {
        let y = lp2.process(lp1.process(hp.process(samples[i])))
        samples[i] = y
        maxAbs = max(maxAbs, abs(y))
    }
    let fade = min(samples.count, Int(0.003 * synthSampleRate))
    for i in 0..<fade {
        samples[samples.count - 1 - i] *= Float(i) / Float(fade)
    }
    guard maxAbs > 0 else { return }
    let scale = peak / maxAbs
    for i in samples.indices { samples[i] *= scale }
}

/// A duck, more or less: a rough sawtooth pushed through nasal formants.
func renderQuack(up: Bool, size: QuackSize, rng: inout RNG) -> [Float] {
    let sr = synthSampleRate
    var dur: Float = 0.12, fStart: Float = 520, fEnd: Float = 330, gain: Float = 1
    switch size {
    case .regular: break
    case .medium: dur = 0.15; fStart = 480; fEnd = 300
    case .large: dur = 0.24; fStart = 430; fEnd = 250; gain = 1.1
    }
    if up {
        dur *= 0.45
        fStart *= 1.25
        fEnd *= 1.3
        gain *= 0.4
    }

    let j = rng.jitter(0.06)
    let n = Int((dur + 0.02) * sr)
    var out = [Float](repeating: 0, count: n)
    var f1 = Biquad.bandpass(1050 * j, q: 5)
    var f2 = Biquad.bandpass(2250 * j, q: 6)
    var f3 = Biquad.bandpass(3300 * j, q: 7)
    var phase: Float = 0
    var subPhase: Float = 0
    let hold = dur * 0.6
    for i in 0..<n {
        let t = Float(i) / sr
        let x = min(t / dur, 1)
        let f0 = (fStart + (fEnd - fStart) * x) * j
        phase += f0 / sr
        phase -= phase.rounded(.down)
        subPhase += 2 * .pi * f0 * 0.5 / sr
        let saw = 2 * phase - 1
        let rough = 1 - 0.45 * (0.5 + 0.5 * sin(subPhase))
        let src = saw * rough + 0.08 * rng.bi()
        let attack = min(t / 0.006, 1)
        let release = t < hold ? 1 : exp(-(t - hold) / (dur * 0.15))
        out[i] = (f1.process(src) + 0.7 * f2.process(src) + 0.3 * f3.process(src) + 0.15 * src) * attack * release
    }
    finish(&out, lowpass: 7000, highpass: 250, peak: 0.45 * gain)
    return out
}
