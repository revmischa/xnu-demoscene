import AVFoundation
import Foundation

// Procedural soundtrack: a 16-step-per-bar tracker driving synth voices, rendered
// sample-by-sample in an AVAudioSourceNode. Everything is synthesized here; no samples.
//
// Arrangement (bars, 128 BPM, 1 bar = 1.875 s):
//   0-8   pad + sparse arp (boot)         48-64 full + open hats (tunnel)
//   8-16  + kick, hats                    64-72 breakdown: pad, riser (panic)
//   16-32 + bass, snare (mach ports)      72-88 drop, lead variation (finale)
//   32-48 + lead (plasma)                 88-100 outro, fades (credits)

let totalBars = 100
let demoLength = Double(totalBars) * 4 * 60 / DemoClock.bpm

@inline(__always) func midiHz(_ n: Double) -> Double { 440 * pow(2, (n - 69) / 12) }

struct Trigger {
    nonisolated(unsafe) static var kick = -10.0
    nonisolated(unsafe) static var snare = -10.0
    nonisolated(unsafe) static var hat = -10.0
    nonisolated(unsafe) static var bass = -10.0
    nonisolated(unsafe) static var lead = -10.0
    nonisolated(unsafe) static var leadNote = 69.0
    nonisolated(unsafe) static var step = 0
}

/// Chamberlin state-variable filter, cheap and stable enough for synth voices.
struct SVF {
    var low = 0.0, band = 0.0
    mutating func process(_ x: Double, cutoff: Double, q: Double, sr: Double) -> Double {
        let f = min(2 * sin(Double.pi * min(cutoff, sr * 0.22) / sr), 0.99)
        low += f * band
        let high = x - low - q * band
        band += f * high
        low += f * band
        return low
    }
}

struct Rng {
    var state: UInt32 = 0x9E3779B9
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Double(state) / Double(UInt32.max) * 2 - 1
    }
}

final class Synth {
    let sr: Double
    let samplesPerStep: Double
    var sample = 0
    var step = -1
    var rng = Rng()

    // drums
    var kickT = 1e9, kickPhase = 0.0
    var snareT = 1e9, snarePhase = 0.0
    var hatT = 1e9, hatOpen = false
    var noiseHP = 0.0

    // bass
    var bassT = 1e9, bassPhase = 0.0, bassFreq = 55.0, bassAccent = 0.0, bassFilter = SVF()
    // lead
    var leadT = 1e9, leadRelT = 1e9, leadPhase1 = 0.0, leadPhase2 = 0.0, leadFreq = 440.0, leadTarget = 440.0, leadFilter = SVF()
    var leadGate = false
    // pad: 3 notes x 2 detuned saws
    var padPhase = [Double](repeating: 0, count: 6)
    var padNotes = [57.0, 60.0, 64.0]
    var padEnv = 0.0
    var padFilterL = SVF(), padFilterR = SVF()
    // arp
    var arpT = 1e9, arpPhase = 0.0, arpFreq = 440.0
    // riser
    var riserFilter = SVF()
    // delay
    var delayL: [Float], delayR: [Float]
    var delayPos = 0
    let delayLen: Int
    var delayFbL = 0.0, delayFbR = 0.0
    // master lowpass used for the breakdown sweep
    var masterL = SVF(), masterR = SVF()

    init(sampleRate: Double) {
        sr = sampleRate
        samplesPerStep = sr * 60 / DemoClock.bpm / 4
        delayLen = Int(samplesPerStep * 3)        // dotted eighth
        delayL = [Float](repeating: 0, count: delayLen)
        delayR = [Float](repeating: 0, count: delayLen)
    }

    // --- song data ---------------------------------------------------------

    // Chord progression in A minor: Am | F | C | G, two bars each. MIDI numbers.
    static let chords: [[Double]] = [[57, 60, 64], [53, 57, 60], [60, 64, 67], [55, 59, 62]]
    static let bassLine: [Int] = [0, -1, 0, 12, -1, 0, -1, 0, 0, -1, 12, 0, -1, 0, -1, 12] // -1 rest
    // Lead: 4-bar phrase, 16th steps. 0 = hold, -1 = rest.
    static let leadA: [Double] = [
        69, 0, 72, 0, 76, 0, 72, 74, 0, 72, 0, 69, 0, 0, -1, -1,
        67, 0, 69, 0, 72, 0, 67, 0, 64, 0, 0, 0, 67, 0, 69, 0,
        69, 0, 72, 0, 76, 0, 79, 0, 77, 0, 76, 0, 72, 0, 74, 0,
        72, 0, 0, 0, 69, 0, 0, 0, 67, 0, 64, 0, 67, 0, 0, -1,
    ]
    static let leadB: [Double] = [
        81, 0, 79, 0, 76, 0, 79, 0, 81, 0, 84, 0, 81, 0, 79, 0,
        77, 0, 76, 0, 72, 0, 76, 0, 77, 0, 79, 0, 76, 0, 72, 0,
        81, 0, 79, 0, 76, 0, 79, 0, 81, 0, 84, 0, 88, 0, 84, 0,
        83, 0, 0, 0, 79, 0, 0, 0, 76, 0, 0, 0, 74, 0, 72, 0,
    ]

    struct Section {
        var pad = true, arp = false, kick = false, hat = false, snare = false
        var bass = false, lead: [Double]? = nil, riser = false, openHat = false
        var sweep = 1.0, fade = 1.0
    }

    static func section(bar: Int) -> Section {
        var s = Section()
        switch bar {
        case 0..<8: s.arp = true
        case 8..<16: s.arp = true; s.kick = true; s.hat = true
        case 16..<32: s.arp = true; s.kick = true; s.hat = true; s.snare = true; s.bass = true
        case 32..<48: s.kick = true; s.hat = true; s.snare = true; s.bass = true; s.lead = leadA; s.arp = bar >= 40
        case 48..<64: s.kick = true; s.hat = true; s.snare = true; s.bass = true; s.lead = leadA; s.arp = true; s.openHat = true
        case 64..<72: s.riser = true; s.kick = bar < 68; s.sweep = 0.08 + Double(bar - 64) / 8 * 0.5
        case 72..<88: s.kick = true; s.hat = true; s.snare = true; s.bass = true; s.lead = leadB; s.arp = true; s.openHat = bar >= 80
        case 88..<100:
            s.arp = true; s.kick = bar < 92; s.hat = bar < 92; s.bass = bar < 92
            s.fade = bar < 96 ? 1 : 1 - Double(bar - 96) / 4
        default: s.pad = false; s.fade = 0
        }
        return s
    }

    // --- sequencer ---------------------------------------------------------

    func onStep(_ step: Int) {
        let bar = step / 16, s16 = step % 16
        let sec = Synth.section(bar: bar)
        let chord = Synth.chords[(bar / 2) % 4]
        let t = Double(sample) / sr
        Trigger.step = step

        if bar >= totalBars { return }
        padNotes = chord

        if sec.kick && (s16 % 4 == 0 || (s16 == 14 && bar % 4 == 3)) {
            kickT = 0; kickPhase = 0; Trigger.kick = t
        }
        if sec.snare && (s16 == 4 || s16 == 12) {
            snareT = 0; snarePhase = 0; Trigger.snare = t
        }
        if sec.hat && s16 % 2 == 0 {
            hatT = 0; hatOpen = sec.openHat && s16 % 4 == 2; Trigger.hat = t
        }
        if sec.bass {
            let n = Synth.bassLine[s16]
            if n >= 0 {
                bassT = 0; bassFreq = midiHz(chord[0] - 24 + Double(n)); bassAccent = s16 % 8 == 0 ? 1 : 0.5
                Trigger.bass = t
            }
        }
        if let lead = sec.lead {
            let n = lead[step % 64]
            if n > 0 {
                leadTarget = midiHz(n); leadGate = true
                if !(leadT < 1e8 && leadRelT > 1e8) { leadFreq = leadTarget }
                leadT = 0; leadRelT = 1e9
                Trigger.lead = t; Trigger.leadNote = n
            } else if n < 0 {
                leadGate = false; leadRelT = 0
            }
        } else if leadGate { leadGate = false; leadRelT = 0 }
        if sec.arp {
            let dense = bar >= 16
            if dense || s16 % 4 == 0 {
                let pattern = [0, 1, 2, 1, 0, 2, 1, 2]
                let note = chord[pattern[s16 % 8] % 3] + 12 + (s16 >= 8 && dense ? 12 : 0)
                arpT = 0; arpFreq = midiHz(note)
            }
        }
    }

    // --- voices ------------------------------------------------------------

    @inline(__always) func saw(_ p: Double) -> Double { 2 * (p - floor(p)) - 1 }
    @inline(__always) func pulse(_ p: Double, _ w: Double) -> Double { (p - floor(p)) < w ? 1 : -1 }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let dt = 1 / sr
        for i in 0..<frames {
            let stepNow = Int(Double(sample) / samplesPerStep)
            if stepNow != step { step = stepNow; onStep(step) }
            let bar = step / 16
            let sec = Synth.section(bar: bar)
            let noise = rng.next()
            noiseHP = noise - noiseHP * 0.5
            let hp = noise - noiseHP

            var dry = 0.0, send = 0.0, sideL = 0.0, sideR = 0.0

            // kick: sine with fast pitch sweep
            if kickT < 0.6 {
                let f = 48 + 140 * exp(-kickT * 28)
                kickPhase += f * dt
                let env = exp(-kickT * 7) * min(kickT * 1500, 1)
                dry += sin(kickPhase * 2 * .pi) * env * 1.1 + hp * exp(-kickT * 400) * 0.6
                kickT += dt
            }
            // snare: noise burst + body
            if snareT < 0.4 {
                snarePhase += 190 * dt
                let s = hp * exp(-snareT * 16) * 0.8 + sin(snarePhase * 2 * .pi) * exp(-snareT * 35) * 0.5
                dry += s; send += s * 0.15
                snareT += dt
            }
            // hats
            if hatT < 0.5 {
                let env = exp(-hatT * (hatOpen ? 9 : 55))
                let h = hp * env * 0.22
                sideL += h; sideR -= h * 0.6
                hatT += dt
            }
            // bass: two detuned saws through a resonant lowpass with envelope
            if bassT < 1.0 {
                bassPhase += bassFreq * dt
                let x = saw(bassPhase) * 0.6 + saw(bassPhase * 1.004 + 0.3) * 0.4 + pulse(bassPhase * 0.5, 0.5) * 0.3
                let env = exp(-bassT * 5) * min(bassT * 800, 1)
                let cutoff = 120 + 2600 * bassAccent * exp(-bassT * 9)
                dry += bassFilter.process(x, cutoff: cutoff, q: 0.45, sr: sr) * env * 0.85
                bassT += dt
            }
            // lead: glide, vibrato, PWM + saw, delay send
            if leadT < 1e8 {
                leadFreq += (leadTarget - leadFreq) * 0.004
                let vib = sin(leadT * 2 * .pi * 5.5) * min(max(leadT - 0.15, 0) * 4, 1) * 0.006
                let f = leadFreq * (1 + vib)
                leadPhase1 += f * dt
                leadPhase2 += f * 1.007 * dt
                let pw = 0.5 + 0.2 * sin(leadT * 3)
                let x = pulse(leadPhase1, pw) * 0.5 + saw(leadPhase2) * 0.5
                let att = min(leadT * 60, 1)
                let rel = leadRelT < 1e8 ? exp(-leadRelT * 9) : 1
                let env = att * rel * (0.6 + 0.4 * exp(-leadT * 2))
                let y = leadFilter.process(x, cutoff: 900 + 2600 * env, q: 0.9, sr: sr) * env * 0.42
                dry += y; send += y * 0.55
                leadT += dt
                if leadRelT < 1e8 { leadRelT += dt; if leadRelT > 1.5 { leadT = 1e9; leadRelT = 1e9 } }
            }
            // pad: 3-note chord, 2 detuned saws per note, slow filter LFO
            if sec.pad || padEnv > 0.001 {
                padEnv += ((sec.pad ? 1.0 : 0.0) - padEnv) * (sec.pad ? 0.000012 : 0.00004)
                var pl = 0.0, pr = 0.0
                for n in 0..<3 {
                    let f = midiHz(padNotes[n])
                    padPhase[n * 2] += f * 0.997 * dt
                    padPhase[n * 2 + 1] += f * 1.003 * dt
                    pl += saw(padPhase[n * 2]); pr += saw(padPhase[n * 2 + 1])
                }
                let tt = Double(sample) * dt
                let cutoff = 500 + 420 * sin(tt * 0.37) + 300 * sin(tt * 0.11)
                sideL += padFilterL.process(pl, cutoff: cutoff, q: 0.6, sr: sr) * padEnv * 0.08
                sideR += padFilterR.process(pr, cutoff: cutoff * 1.1, q: 0.6, sr: sr) * padEnv * 0.08
            }
            // arp: plucky triangle, mostly wet
            if arpT < 0.5 {
                arpPhase += arpFreq * dt
                let p = arpPhase - floor(arpPhase)
                let tri = 4 * abs(p - 0.5) - 1
                let x = (tri * 0.7 + pulse(arpPhase, 0.25) * 0.3) * exp(-arpT * 14) * 0.2
                dry += x * 0.5; send += x
                arpT += dt
            }
            // riser: noise through a rising bandpass for the breakdown
            if sec.riser {
                let prog = (Double(sample) / samplesPerStep / 16 - 64) / 8
                let p = max(0, min(prog, 1))
                let cutoff = 200 + 6000 * p * p
                let y = riserFilter.process(noise, cutoff: cutoff, q: 0.25, sr: sr)
                let r = riserFilter.band * 0.18 * p + y * 0.02
                sideL += r; sideR += r * 0.8
            }

            // ping-pong delay
            let dl = Double(delayL[delayPos]), dr = Double(delayR[delayPos])
            delayFbL += (dr - delayFbL) * 0.35
            delayFbR += (dl - delayFbR) * 0.35
            delayL[delayPos] = Float(send + delayFbL * 0.45)
            delayR[delayPos] = Float(delayFbR * 0.45)
            delayPos += 1; if delayPos >= delayLen { delayPos = 0 }

            var l = dry + sideL + dl * 0.7
            var r = dry + sideR + dr * 0.7
            if sec.sweep < 1 {
                let c = 150 + 9000 * sec.sweep * sec.sweep
                l = masterL.process(l, cutoff: c, q: 0.7, sr: sr)
                r = masterR.process(r, cutoff: c, q: 0.7, sr: sr)
            }
            let g = 0.75 * sec.fade
            left[i] = Float(tanh(l * g))
            right[i] = Float(tanh(r * g))
            sample += 1
        }
    }
}

final class Audio {
    static let shared = Audio()
    let engine = AVAudioEngine()
    var synth: Synth!
    var source: AVAudioSourceNode!

    func start() {
        let out = engine.outputNode
        let sr = out.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        synth = Synth(sampleRate: sr)
        let synth = self.synth!
        source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            DemoClock.markStartIfNeeded()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let l = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let r = abl[1].mData!.assumingMemoryBound(to: Float.self)
            synth.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: out, format: nil)
        engine.mainMixerNode.outputVolume = 1
        do { try engine.start() } catch { fputs("audio engine failed: \(error)\n", stderr) }
    }
}
