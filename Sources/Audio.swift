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

/// Trapezoidal (Zavalishin) state-variable filter. Stable at any cutoff, unlike the
/// Chamberlin form, which blows up when cutoff is high and damping is low.
/// `q` is the damping term k (= 1/Q): 2 is no resonance, 0.3 is screaming.
struct SVF {
    var ic1 = 0.0, ic2 = 0.0
    var low = 0.0, band = 0.0
    mutating func process(_ x: Double, cutoff: Double, q: Double, sr: Double) -> Double {
        let g = tan(Double.pi * min(max(cutoff, 10), sr * 0.45) / sr)
        let k = q
        let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        low = v2; band = v1
        return v2
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

    // bass: sub sine + growl layer through a wobbling resonant lowpass, sidechained to the kick
    var bassT = 1e9, bassRelT = 1e9, bassPhase = 0.0, subPhase = 0.0, bassFreq = 55.0, bassTarget = 55.0, bassAccent = 0.0
    var bassFilter = SVF(), bassFilter2 = SVF()
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
    // Wobble sections hold long notes and let the filter LFO do the talking. -2 = note off.
    static let wobbleLine: [Int] = [0, -1, -1, -1, -1, -1, -2, 0, -1, -1, -2, 3, -1, -2, -5, -1]
    // Wobble rate in cycles per beat, per bar: 1/4, 1/8, 1/16, triplets, ...
    static let wobbleRates: [Double] = [1, 2, 4, 3, 2, 8, 4, 1.5]
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
        var wobble = false, halfTime = false   // dubstep-style drop: LFO on the bass filter, snare on 3 only
        var sweep = 1.0, fade = 1.0
    }

    static func section(bar: Int) -> Section {
        var s = Section()
        switch bar {
        case 0..<8: s.arp = true
        case 8..<16: s.arp = true; s.kick = true; s.hat = true
        case 16..<32: s.arp = true; s.kick = true; s.hat = true; s.snare = true; s.bass = true
        case 32..<48: s.kick = true; s.hat = true; s.snare = true; s.bass = true; s.lead = leadA; s.arp = bar >= 40
        case 48..<64: s.kick = true; s.hat = true; s.snare = true; s.bass = true; s.lead = leadA; s.arp = true; s.openHat = true; s.wobble = bar >= 56
        case 64..<72: s.riser = true; s.kick = bar < 68; s.sweep = 0.08 + Double(bar - 64) / 8 * 0.5
        case 72..<88: s.kick = true; s.hat = true; s.snare = true; s.bass = true; s.lead = bar >= 80 ? leadB : nil; s.arp = bar >= 80; s.wobble = true; s.halfTime = true; s.openHat = bar >= 80
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

        let kickHit = sec.halfTime ? (s16 == 0 || s16 == 6 || s16 == 10 || (s16 == 14 && bar % 2 == 1)) : (s16 % 4 == 0 || (s16 == 14 && bar % 4 == 3))
        if sec.kick && kickHit {
            kickT = 0; kickPhase = 0; Trigger.kick = t
        }
        if sec.snare && (sec.halfTime ? s16 == 8 : (s16 == 4 || s16 == 12)) {
            snareT = 0; snarePhase = 0; Trigger.snare = t
        }
        if sec.hat && s16 % 2 == 0 {
            hatT = 0; hatOpen = sec.openHat && s16 % 4 == 2; Trigger.hat = t
        }
        if sec.bass {
            let n = (sec.wobble ? Synth.wobbleLine : Synth.bassLine)[s16]
            if n >= -1 && n != -1 {
                let legato = sec.wobble && bassT < 1e8 && bassRelT > 1e8
                bassTarget = midiHz(chord[0] - 24 + Double(n))
                if !legato { bassFreq = bassTarget; bassPhase = 0; subPhase = 0 }
                bassT = 0; bassRelT = 1e9; bassAccent = s16 % 8 == 0 ? 1 : 0.6
                Trigger.bass = t
            } else if n == -2 && bassT < 1e8 { bassRelT = 0 }
        } else if bassT < 1e8 && bassRelT > 1e8 { bassRelT = 0 }
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
            var duck = 1.0
            if kickT < 0.7 {
                let f = 42 + 150 * exp(-kickT * 24)
                kickPhase += f * dt
                let env = exp(-kickT * 5.5) * min(kickT * 1500, 1)
                let body = sin(kickPhase * 2 * .pi)
                dry += tanh(body * 1.6) * env * 1.0 + hp * exp(-kickT * 300) * 0.7
                duck = 1 - 0.85 * exp(-kickT * 14)   // sidechain: bass and pad pump on every kick
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
            // bass: sub sine + distorted saw stack through a wobbling resonant lowpass
            if bassT < 1e8 {
                bassFreq += (bassTarget - bassFreq) * 0.003
                let f = bassFreq
                subPhase += f * dt
                bassPhase += f * 2 * dt
                let sub = sin(subPhase * 2 * .pi)
                let stack = saw(bassPhase) + saw(bassPhase * 1.011 + 0.2) * 0.8 + saw(bassPhase * 0.5 * 0.994) * 0.6 + pulse(bassPhase * 2, 0.3) * 0.4
                let att = min(bassT * 600, 1)
                let rel = bassRelT < 1e8 ? exp(-bassRelT * 14) : 1
                let cutoff: Double
                if sec.wobble {
                    let rate = Synth.wobbleRates[bar % 8]
                    let beatPos = Double(sample) / samplesPerStep / 4
                    let lfo = 0.5 - 0.5 * cos(2 * .pi * beatPos * rate)
                    cutoff = 90 + 3200 * lfo * lfo
                } else {
                    cutoff = 110 + 2800 * bassAccent * exp(-bassT * 8)
                }
                let growl = bassFilter.process(tanh(stack * 2.2), cutoff: cutoff, q: 0.35, sr: sr)
                let growl2 = bassFilter2.process(growl, cutoff: cutoff * 1.5 + 200, q: 1.2, sr: sr)
                let subEnv = sec.wobble ? 1.0 : exp(-bassT * 2.5)
                let env = att * rel * duck
                let y = sub * subEnv * 1.0 + tanh(growl2 * 2.0) * 0.55
                dry += y * env * (sec.wobble ? 1.0 : 0.85)
                bassT += dt
                if bassRelT < 1e8 { bassRelT += dt; if bassRelT > 0.6 { bassT = 1e9; bassRelT = 1e9 } }
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
                sideL += padFilterL.process(pl, cutoff: cutoff, q: 0.6, sr: sr) * padEnv * 0.08 * duck
                sideR += padFilterR.process(pr, cutoff: cutoff * 1.1, q: 0.6, sr: sr) * padEnv * 0.08 * duck
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
            let g = 0.55 * sec.fade
            if !l.isFinite || !r.isFinite { l = 0; r = 0 }   // insurance: a NaN would otherwise live in the delay line forever
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
        synth.sample = Int(startAt * sr)
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

func renderAudioFile(to path: String) {
    let sr = 48000.0
    let synth = Synth(sampleRate: sr)
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let frames = Int(demoLength * sr)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
    synth.render(frames: frames, left: l, right: r)
    buf.frameLength = AVAudioFrameCount(frames)
    // Self-check: finite everywhere, audible in every 16-bar block except the fade-out.
    let block = Int(sr * 60 / DemoClock.bpm * 64)
    var ok = true
    for b in stride(from: 0, to: frames, by: block) {
        var sum = 0.0, peak = 0.0
        for i in b..<min(b + block, frames) {
            let v = Double(l[i]), w = Double(r[i])
            if !v.isFinite || !w.isFinite { ok = false }
            sum += v * v + w * w; peak = max(peak, abs(v), abs(w))
        }
        let rms = 20 * log10(sqrt(sum / Double(2 * block)) + 1e-9)
        let silent = rms < -40 && b / block < 6
        if silent { ok = false }
        fputs(String(format: "bars %3d-%3d  rms %6.1f dB  peak %.2f%@\n", b / block * 16, b / block * 16 + 16, rms, peak, silent ? "  SILENT" : ""), stderr)
    }
    if !ok { fputs("audio self-check FAILED\n", stderr); exit(1) }
    do {
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
        try file.write(from: buf)
    } catch { fputs("render failed: \(error)\n", stderr); exit(1) }
}
