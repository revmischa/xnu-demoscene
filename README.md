# xnu-demo

A native macOS / XNU demoscene production: a 3-minute, fullscreen, real-time
audiovisual demo with Metal shaders and a procedurally synthesized soundtrack,
themed around the Mach/XNU kernel and Darwin. The demo reads live kernel data
(process list, per-core load, Mach ports, uptime, kernel version) and weaves it
into the visuals, so it is a little different on every machine.

*[Built by Claude Fable 5.1, per Mischa]*

## Requirements

- Apple Silicon Mac, macOS 14 or newer (developed on macOS 27 / Darwin 27, Swift 6.4)
- Xcode command-line tools (`swiftc`). The Metal command-line toolchain is **not**
  required: shaders are compiled at runtime with `MTLDevice.makeLibrary(source:)`.
- No third-party dependencies, no assets, no Xcode project.

## Build and run

```sh
make          # builds ./xnu-demo
make run      # fullscreen on the main display
make check    # renders the soundtrack offline and asserts it is finite and audible
```

Dev flags:

```sh
./xnu-demo --windowed                 # 1280x720 window instead of fullscreen
./xnu-demo --windowed --at 72         # start the demo clock and sequencer at 72 s
./xnu-demo --windowed --at 72 --shot f.png   # save a frame 1.5 s later and quit
./xnu-demo --render-audio track.wav   # render the soundtrack offline (no window)
```

## Controls

- **Esc** or **q**: quit. The demo also quits by itself after the credits.

## How it works

Everything lives in `Sources/`:

| File | What |
|------|------|
| `main.swift` | `NSApplication` with `.regular` activation, borderless shielding-level window, cursor hidden, Esc handler. |
| `Renderer.swift` | `MTKViewDelegate`. Scene pass (rgba16f, capped at ~1080p) → bright pass → two-pass blur → post pass (bloom, chromatic aberration, scanlines, CRT curvature, vignette, grain, tone map). Fills the `Uniforms` struct every frame. |
| `Shaders.metal` | One fragment function per scene selected by a scene index, the text overlay, and the post chain. Embedded as a Swift string by the Makefile. |
| `Audio.swift` | `AVAudioSourceNode` render block driving a 16-step-per-bar tracker at 128 BPM and the synth voices. |
| `Text.swift` | Glyph atlas rendered from the system monospaced font at startup, a CPU-side glyph grid uploaded as an RG8 texture, and the per-scene text content. |
| `SystemInfo.swift` | Live XNU data sampled at 2 Hz, plus the `mach_absolute_time` demo clock. |

### Clock and sync

The demo clock is `mach_absolute_time()` scaled by `mach_timebase_info`, zeroed by the
first audio render callback so visuals and sequencer share an origin. The sequencer
counts samples: step = floor(sample / (sr · 60 / BPM / 4)). When a drum or note fires
it records the time; the renderer turns those into decaying pulses (`kick`, `snare`,
`hat`, `bass`, `lead` uniforms) that drive scale, brightness, chromatic aberration
and the copper bars, so effects land on the audio, not on a guessed beat.

### Soundtrack

All synthesized in the render block, sample by sample:

- **Kick** sine with a fast pitch sweep plus a noise click. **Snare** noise burst plus
  a 190 Hz body. **Hats** high-passed noise, closed and open.
- **Bass** two detuned saws plus a sub pulse through a resonant lowpass with an
  envelope on cutoff (acid-ish), notes from a 16-step pattern relative to the chord.
- **Lead** PWM pulse plus saw with glide and vibrato, two 4-bar phrases (A and B).
- **Pad** three-note chord, two detuned saws per note, slow filter LFO.
- **Arp** plucked triangle cycling chord tones, mostly wet.
- **Riser** noise through a rising bandpass for the kernel-panic breakdown.
- Ping-pong delay at a dotted eighth, master lowpass sweep in the breakdown,
  `tanh` soft clip.

Chords: Am | F | C | G, two bars each. Filters are trapezoidal state-variable
filters (stable at any cutoff). Arrangement by bar is in `Synth.section(bar:)`.

### Scenes (bars at 128 BPM, 1.875 s per bar)

| Bars | Scene | What you see |
|------|-------|--------------|
| 0–16 | **boot** | Starfield and a grid floor. A kernel boot log types itself out using the real `kern.version`, `hw.model`, `hw.ncpu`, page counts, `mach_timebase_info`, and the live process list sorted by pid. |
| 16–32 | **mach ports** | Raymarched metaball "tasks" whose radius follows per-core CPU load (`host_processor_info`). Glowing messages fly between them on the beat. Each sphere is labelled with a live process; the HUD shows `mach_port_names`, `task_threads`, load average and memory pressure. |
| 32–48 | **plasma / proc rain** | Classic plasma, scale driven by load average, with the live process list raining down as glyph columns. |
| 48–64 | **tunnel** | Grid tunnel morphing between round and square, speed driven by load, rings fired on hats. |
| 64–72 | **kernel panic** | A full XNU-style panic log with the real kernel version, model, uptime, per-core "PC/LR/FP" lines with live load, a victim process picked from the process list, glitch tearing that worsens over time, then a block dissolve. |
| 72–88 | **xnu finale** | Raymarched chrome "XNU" letters built from SDF boxes and arcs, copper-bar sky reflected in them, synthwave grid floor with reflections, edges glowing on the lead. |
| 88–100 | **credits** | Credits, a rotozoom checker, and a rainbow sine scroller with greetz. |

### Live XNU data used

`kern.version`, `kern.osversion`, `kern.osrelease`, `hw.model`, `hw.machine`,
`hw.ncpu`, `hw.memsize`, `hw.pagesize`, `kern.boottime`, `kern.memorystatus_level`
(sysctl); `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` per-core load;
`KERN_PROC_ALL` process list; `mach_port_names` and `task_threads` on the demo's
own task; `getloadavg`; `mach_absolute_time` / `mach_timebase_info`.
