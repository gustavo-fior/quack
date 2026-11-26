import CoreGraphics
import Foundation
import os

/// The settings the input thread needs, copied out of AppState whenever they change.
struct LiveConfig {
    var active = false
    var packIndex = 0
    var volume: Float = 0.7
    var keyUp = true
    var modifiers = true
    var repeats = false
    var mouse = false
    var scroll = false
    var stereoWidth: Float = 0.6
    var pitchVariation: Float = 0.03
    var toneX: Float = 0
    var toneY: Float = 0
}

enum KeyLayout {
    /// Horizontal position of each key on an ANSI board, 0 (left) to 1 (right).
    static let position: [Int: Float] = {
        let rows: [(offset: Float, keys: [Int])] = [
            (0, [53, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]),
            (0, [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 51]),
            (0.3, [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]),
            (0.5, [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 36]),
            (0.9, [56, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 60]),
        ]
        var map: [Int: Float] = [:]
        for row in rows {
            for (i, key) in row.keys.enumerated() {
                map[key] = min((Float(i) + row.offset + 0.5) / 14.5, 1)
            }
        }
        // Bottom row, arrows and the numpad.
        let extras: [Int: Float] = [
            63: 0.03, 59: 0.1, 58: 0.17, 55: 0.25, 49: 0.5, 54: 0.72, 61: 0.79, 62: 0.85,
            123: 0.86, 125: 0.92, 126: 0.92, 124: 0.98, 76: 0.98, 117: 0.95,
        ]
        map.merge(extras) { _, new in new }
        return map
    }()

    static func pan(for keyCode: Int) -> Float {
        ((position[keyCode] ?? 0.95) - 0.5) * 2
    }

    private static let rows: [Int: KeySlot] = {
        let table: [(KeySlot, [Int])] = [
            (.row0, [53, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]),
            (.row1, [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]),
            (.row2, [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]),
            (.row3, [56, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 60, 126]),
            (.row4, [63, 59, 58, 55, 54, 61, 62, 123, 124, 125]),
            (.space, [49]),
            (.enter, [36, 76]),
            (.backspace, [51, 117]),
        ]
        var map: [Int: KeySlot] = [:]
        for (slot, keys) in table { for key in keys { map[key] = slot } }
        return map
    }()

    static func slot(for keyCode: Int) -> KeySlot {
        rows[keyCode] ?? .row2
    }

    static func modifierFlag(for keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        case 57: return .maskAlphaShift
        default: return nil
        }
    }
}

/// Turns input events into sounds. Called on the event tap thread.
final class Player {
    let mixer: AudioMixer
    let packs: [PackSamples?]

    private enum Source {
        case key(Int)
        case mouse
        case scroll
    }

    private struct State {
        var config = LiveConfig()
        var rng = RNG(state: UInt64(Date().timeIntervalSince1970 * 1000))
        var heldModifiers = Set<Int>()
        var lastScroll: UInt64 = 0
        var pendingKeys = 0
    }

    private struct Shot {
        var buffer: SampleBuffer
        var rate: Float
        var gain: Float
        var pan: Float
        var tone: Float
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(mixer: AudioMixer, packs: [PackSamples?]) {
        self.mixer = mixer
        self.packs = packs
    }

    func update(_ config: LiveConfig) {
        state.withLock { $0.config = config }
    }

    /// Key presses counted since the last call. Only a number is kept, never the keys themselves.
    func drainKeyCount() -> Int {
        state.withLock {
            let n = $0.pendingKeys
            $0.pendingKeys = 0
            return n
        }
    }

    func handle(_ event: InputEvent) {
        let packs = self.packs
        let shot: Shot? = state.withLock { s in
            guard s.config.active else { return nil }
            let c = s.config
            switch event.kind {
            case .keyDown:
                if event.isRepeat {
                    return c.repeats ? Self.shot(&s, packs, up: false, source: .key(event.keyCode)) : nil
                }
                s.pendingKeys += 1
                return Self.shot(&s, packs, up: false, source: .key(event.keyCode))
            case .keyUp:
                return c.keyUp ? Self.shot(&s, packs, up: true, source: .key(event.keyCode)) : nil
            case .flagsChanged:
                guard let flag = KeyLayout.modifierFlag(for: event.keyCode) else { return nil }
                let down: Bool
                if event.keyCode == 57 {
                    // Caps Lock reports a single change per press.
                    down = true
                } else if !event.flags.contains(flag) {
                    s.heldModifiers.remove(event.keyCode)
                    down = false
                } else if s.heldModifiers.contains(event.keyCode) {
                    // The flag is still set by the key on the other side.
                    s.heldModifiers.remove(event.keyCode)
                    down = false
                } else {
                    s.heldModifiers.insert(event.keyCode)
                    down = true
                }
                if down { s.pendingKeys += 1 }
                guard c.modifiers, down || c.keyUp else { return nil }
                return Self.shot(&s, packs, up: !down, source: .key(event.keyCode))
            case .mouseDown:
                return c.mouse ? Self.shot(&s, packs, up: false, source: .mouse) : nil
            case .mouseUp:
                return c.mouse && c.keyUp ? Self.shot(&s, packs, up: true, source: .mouse) : nil
            case .scroll:
                guard c.scroll else { return nil }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now &- s.lastScroll > 45_000_000 else { return nil }
                s.lastScroll = now
                return Self.shot(&s, packs, up: false, source: .scroll)
            }
        }
        if let shot {
            play(shot)
        } else if event.kind == .mouseDown, state.withLock({ $0.config.active }) {
            // A click usually comes before typing, so the engine is started now and the
            // first key doesn't have to wait for it.
            mixer.warm()
        }
    }

    /// Plays one key from a pack regardless of whether Quack is enabled. Used for previews.
    func playSample(pack: Int, up: Bool, keyCode: Int) {
        let packs = self.packs
        let shot: Shot? = state.withLock { s in
            Self.shot(&s, packs, up: up, source: .key(keyCode), packOverride: pack)
        }
        if let shot { play(shot) }
    }

    /// Types a short phrase so a pack can be heard without touching the keyboard.
    func preview(pack: Int) {
        // "quack", space, "quack", return.
        let keys = [12, 32, 0, 8, 40, 49, 12, 32, 0, 8, 40, 36]
        var time = 0.0
        var rng = SystemRandomNumberGenerator()
        for key in keys {
            let hold = Double.random(in: 0.05...0.085, using: &rng)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + time) {
                self.playSample(pack: pack, up: false, keyCode: key)
            }
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + time + hold) {
                self.playSample(pack: pack, up: true, keyCode: key)
            }
            time += Double.random(in: 0.085...0.15, using: &rng) + (key == 49 ? 0.08 : 0)
        }
    }

    private func play(_ shot: Shot) {
        mixer.trigger(shot.buffer, rate: shot.rate, gain: shot.gain, pan: shot.pan, tone: shot.tone)
    }

    private static func shot(
        _ s: inout State, _ packs: [PackSamples?], up: Bool, source: Source, packOverride: Int? = nil
    ) -> Shot? {
        let c = s.config
        let index = packOverride ?? c.packIndex
        guard packs.indices.contains(index), let pack = packs[index] else { return nil }

        let buffer: SampleBuffer
        var rate: Float = 1
        var gain: Float = 1
        var pan: Float = 0
        switch source {
        case .key(let keyCode):
            let slot = KeyLayout.slot(for: keyCode).rawValue
            buffer = up ? pack.release[slot] : pack.press[slot]
            // Each key keeps its own slight detune, like the keys on a real board.
            rate = 1 + (Float((keyCode &* 2_654_435_761) % 1000) / 1000 - 0.5) * 0.05
            pan = KeyLayout.pan(for: keyCode) * c.stereoWidth
        case .mouse:
            // A mouse button is a small, light switch: the release recording, pitched up.
            buffer = pack.release[KeySlot.row2.rawValue]
            rate = up ? 1.5 : 1.25
            gain = up ? 0.4 : 0.6
        case .scroll:
            buffer = pack.release[KeySlot.row2.rawValue]
            rate = 1.8
            gain = 0.18
        }

        rate *= buffer.baseRate * pow(2, c.toneX * 0.45) * (1 + s.rng.bi() * c.pitchVariation)
        gain *= c.volume * c.volume * 1.6 * (1 + s.rng.bi() * 0.1)
        return Shot(buffer: buffer, rate: rate, gain: gain, pan: pan, tone: c.toneY)
    }
}
