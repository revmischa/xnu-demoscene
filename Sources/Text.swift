import AppKit
import Metal

/// A CPU-side glyph grid uploaded each frame as an RG8 texture: R = ASCII code, G = intensity.
/// The scene shader samples the glyph atlas per cell; this is the "terminal" layer.
final class TextLayer {
    let cols: Int, rows: Int
    private var buf: [UInt8]
    init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows; buf = [UInt8](repeating: 0, count: cols * rows * 2) }

    func reset() { for i in 0..<buf.count { buf[i] = 0 } }

    func put(_ row: Int, _ col: Int, _ s: String, intensity: Float = 1, maxLen: Int = .max) {
        guard row >= 0, row < rows else { return }
        var c = col
        let iv = UInt8(max(0, min(intensity, 1)) * 255)
        for ch in s.utf8.prefix(maxLen) {
            if c >= 0 && c < cols {
                let i = (row * cols + c) * 2
                buf[i] = ch >= 32 && ch < 127 ? ch : 63
                buf[i + 1] = iv
            }
            c += 1
        }
    }

    func putCentered(_ row: Int, _ s: String, intensity: Float = 1) {
        put(row, (cols - s.count) / 2, s, intensity: intensity)
    }

    func upload(to tex: MTLTexture) {
        buf.withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0, withBytes: p.baseAddress!, bytesPerRow: cols * 2)
        }
    }
}

/// Renders printable ASCII (32..126) with the system monospaced font into a 16x6 cell
/// atlas at startup. No image assets: the font is the only "asset" and it ships with macOS.
enum GlyphAtlas {
    static let cellW = 32, cellH = 64, gridCols = 16, gridRows = 6

    static func make(device: MTLDevice) -> MTLTexture {
        let w = cellW * gridCols, h = cellH * gridRows
        var pixels = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = pixels.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        }
        let font = NSFont.monospacedSystemFont(ofSize: 44, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        for code in 32...126 {
            let idx = code - 32
            let cx = (idx % gridCols) * cellW, cy = h - (idx / gridCols + 1) * cellH
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(UnicodeScalar(code)!), attributes: attrs))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            ctx.textPosition = CGPoint(x: CGFloat(cx) + (CGFloat(cellW) - width) / 2, y: CGFloat(cy) + (CGFloat(cellH) - ascent - descent) / 2 + descent)
            CTLineDraw(line, ctx)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        let tex = device.makeTexture(descriptor: d)!
        pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w) }
        return tex
    }
}

/// Per-scene text content. Keeps a little state (boot log lines, rain columns) that is
/// rebuilt whenever the scene changes.
enum TextScenes {
    nonisolated(unsafe) static var scene: Int32 = -1
    nonisolated(unsafe) static var lines: [String] = []
    nonisolated(unsafe) static var rain: [(col: Int, y: Double, speed: Double, text: String)] = []
    nonisolated(unsafe) static var lastT = 0.0
    nonisolated(unsafe) static var rng = Rng()

    static func rand() -> Double { (rng.next() + 1) / 2 }
    static func hex(_ n: UInt64) -> String { String(format: "0x%016llx", n) }

    static func update(text: TextLayer, u: inout Uniforms, sys: SystemSnapshot, t: Double, sceneTime: Double) {
        let dt = max(min(t - lastT, 0.1), 0)
        lastT = t
        if u.scene != scene { scene = u.scene; rebuild(sys: sys, text: text) }
        switch u.scene {
        case 0: boot(text, sceneTime)
        case 1: hud(text, sys, t)
        case 2: rainFrame(text, sys, dt)
        case 3: text.put(text.rows - 2, 2, String(format: "uptime %.0fs  kern.osrelease %@  loadavg %.2f  mem %.0f%%", sys.uptime, sys.osRelease, sys.loadAvg * Float(sys.ncpu), sys.memPressure * 100), intensity: 0.45)
        case 4: panic(text, sceneTime, u)
        case 5: text.putCentered(text.rows - 2, "Darwin \(sys.osRelease)  ·  \(xnuBuild(sys))  ·  \(sys.model)", intensity: 0.4)
        case 6: credits(text, &u, sceneTime, sys)
        default: break
        }
    }

    static func xnuBuild(_ sys: SystemSnapshot) -> String {
        // kern.version ends with "root:xnu-13432.1.9~1/RELEASE_ARM64_T6050"
        if let r = sys.kernVersion.range(of: "xnu-") {
            return String(sys.kernVersion[r.lowerBound...]).split(separator: "/").first.map(String.init) ?? "xnu"
        }
        return "xnu"
    }

    static func rebuild(sys: SystemSnapshot, text: TextLayer) {
        text.reset()
        switch scene {
        case 0: lines = bootLines(sys)
        case 2:
            rain = []
            for c in stride(from: 1, to: text.cols - 1, by: 3) {
                rain.append((c, -rand() * 60, 6 + rand() * 14, procLabel(sys)))
            }
        case 4: lines = panicLines(sys)
        default: lines = []
        }
    }

    static func procLabel(_ sys: SystemSnapshot) -> String {
        guard !sys.processes.isEmpty else { return "kernel_task" }
        let p = sys.processes[Int(rand() * Double(sys.processes.count)) % sys.processes.count]
        return "\(p.pid) \(p.name)"
    }

    // --- scene 0: boot log --------------------------------------------------

    static func bootLines(_ sys: SystemSnapshot) -> [String] {
        let pages = sys.memSize / UInt64(max(sys.pageSize, 1))
        var tb = mach_timebase_info(); mach_timebase_info(&tb)
        var l = [String]()
        l.append("iBoot: entering kernel: xnu-demo")
        l.append(sys.kernVersion)
        l.append("hw.model: \(sys.model)   hw.machine: \(sys.machine)   hw.ncpu: \(sys.ncpu)")
        l.append("kern.osversion: \(sys.osVersion)   kern.osrelease: \(sys.osRelease)")
        l.append("mach_timebase_info: numer=\(tb.numer) denom=\(tb.denom)")
        l.append("vm_page_bootstrap: \(pages) pages, pagesize \(sys.pageSize), memsize \(sys.memSize / 1_073_741_824) GB")
        l.append("pmap_startup(): pmap_bootstrap done, ARM64 T-series, PAN enabled")
        l.append("zone_init: kalloc_type zones ready, early boot zones sealed")
        l.append("IOKit Component Version \(sys.osRelease)")
        l.append("Kernel boot args: -v xnu-demo=1 debug=0x144")
        l.append("ml_processor_register: \(sys.ncpu) cpus, cluster P/E topology discovered")
        l.append("mach_msg: IPC namespace ready, \(sys.machPorts) port names in task")
        l.append("task_threads: \(sys.threadCount) threads in kernel_task")
        l.append("BSD root: APFS, major 1, minor 1")
        l.append("launchd[1]: starting userspace")
        let procs = sys.processes.sorted { $0.pid < $1.pid }
        for p in procs.prefix(60) {
            l.append(String(format: "spawn  pid %6d  %@", p.pid, p.name))
        }
        l.append("host_processor_info: PROCESSOR_CPU_LOAD_INFO sampling @ 2 Hz")
        l.append("AVAudioEngine: AVAudioSourceNode attached, 128 BPM tracker online")
        l.append("MTLDevice: \(MTLCreateSystemDefaultDevice()?.name ?? "GPU") — shaders compiled at runtime")
        l.append("Timeline: 7 scenes, 100 bars, \(Int(demoLength)) s")
        l.append("")
        l.append("xnu-demo: all systems go. press ESC to panic.")
        return l
    }

    static func boot(_ text: TextLayer, _ st: Double) {
        text.reset()
        let visible = min(Int(st * st * 0.12 + st * 0.6), lines.count)
        let partial = st * st * 0.12 + st * 0.6 - Double(visible)
        let maxRows = text.rows - 2
        let start = max(0, visible + 1 - maxRows)
        for i in start..<visible {
            let age = Double(visible - i)
            text.put(i - start + 1, 2, lines[i], intensity: Float(0.55 + 0.45 * exp(-age * 0.12)), maxLen: text.cols - 4)
        }
        if visible < lines.count {
            let chars = Int(partial * Double(lines[visible].count + 1))
            let row = visible - start + 1
            text.put(row, 2, String(lines[visible].prefix(chars)), intensity: 1, maxLen: text.cols - 4)
            if Int(st * 4) % 2 == 0 { text.put(row, 2 + chars, "_", intensity: 1) }
        } else if Int(st * 2) % 2 == 0 {
            text.put(visible - start + 1, 2, "_", intensity: 1)
        }
    }

    // --- scene 1: live HUD ----------------------------------------------------

    static func hud(_ text: TextLayer, _ sys: SystemSnapshot, _ t: Double) {
        text.reset()
        let ramp = Array(" .:-=+*#%@")
        var bars = ""
        for l in sys.cpuLoad { bars.append(ramp[min(Int(l * 9.99), 9)]) }
        text.put(text.rows - 4, 2, "host_processor_info  [\(bars)]  \(sys.ncpu) cpus", intensity: 0.6)
        text.put(text.rows - 3, 2, String(format: "mach_port_names %d   task_threads %d   procs %d   loadavg %.2f", sys.machPorts, sys.threadCount, sys.processes.count, sys.loadAvg * Float(sys.ncpu)), intensity: 0.6)
        text.put(text.rows - 2, 2, String(format: "mach_msg_trap  ipc_kmsg  %@  mem pressure %.0f%%", hex(mach_absolute_time()), sys.memPressure * 100), intensity: 0.5)
        text.put(1, 2, "task_for_pid()  →  mach ports  →  messages", intensity: 0.5)
    }

    // --- scene 2: process rain ------------------------------------------------

    static func rainFrame(_ text: TextLayer, _ sys: SystemSnapshot, _ dt: Double) {
        text.reset()
        for i in 0..<rain.count {
            rain[i].y += rain[i].speed * dt
            let n = rain[i].text.count
            if rain[i].y - Double(n) > Double(text.rows) + 2 {
                rain[i] = (rain[i].col, -rand() * 20, 6 + rand() * 14, procLabel(sys))
            }
            let head = Int(rain[i].y)
            for (k, ch) in rain[i].text.utf8.enumerated() {
                let row = head - k
                let inten = k == 0 ? 1.0 : 0.75 * (1 - Double(k) / Double(n))
                text.put(row, rain[i].col, String(UnicodeScalar(ch)), intensity: Float(inten))
            }
        }
    }

    // --- scene 4: kernel panic ----------------------------------------------

    static func panicLines(_ sys: SystemSnapshot) -> [String] {
        func h64() -> UInt64 { UInt64(rand() * Double(UInt32.max)) << 32 | UInt64(rand() * Double(UInt32.max)) }
        let kslide = UInt64(rand() * 0x1fff_ffff) & ~0x3fff
        let ktext: UInt64 = 0xfffffe0007004000 + kslide
        let cpu = Int(rand() * Double(sys.ncpu))
        let victim = sys.processes.randomElement()?.name ?? "xnu-demo"
        var l = [String]()
        l.append("panic(cpu \(cpu) caller \(hex(ktext + 0x3a1f20))): \"demoscene overflow: scene 4 exceeded reality budget\" @xnu_demo.c:1337")
        l.append("Debugger message: panic")
        l.append("Memory ID: 0x6")
        l.append("OS release type: User")
        l.append("OS version: \(sys.osVersion)")
        l.append("Kernel version: \(sys.kernVersion)")
        l.append("Fileset Kernelcache UUID: \(uuid())")
        l.append("Kernel UUID: \(uuid())")
        l.append("Boot session UUID: \(uuid())")
        l.append("iBoot version: iBoot-\(13000 + Int(rand() * 999)).\(Int(rand() * 9)).\(Int(rand() * 9))")
        l.append("secure boot?: YES")
        l.append("roots installed: 0")
        l.append("Paniclog version: 14")
        l.append("Kernel slide:      \(hex(kslide))")
        l.append("Kernel text base:  \(hex(ktext))")
        l.append("mach_absolute_time: \(hex(mach_absolute_time()))")
        l.append("Epoch Time:        sec       usec")
        let now = Date().timeIntervalSince1970
        l.append(String(format: "  Boot    : 0x%08x 0x%08x", UInt32(now - sys.uptime), 0))
        l.append(String(format: "  Calendar: 0x%08x 0x%08x", UInt32(now), UInt32((now - floor(now)) * 1e6)))
        l.append("")
        l.append("Zone info:")
        l.append("  Zone map: 0xfffffe1000000000 - 0xfffffe3000000000")
        l.append("  . VM    : 0xfffffe1000000000 - 0xfffffe1800000000")
        l.append("  . RO    : 0xfffffe1800000000 - 0xfffffe1a00000000")
        l.append("  . GEN0  : 0xfffffe1a00000000 - 0xfffffe2000000000")
        for c in 0..<min(sys.ncpu, 8) {
            let load = c < sys.cpuLoad.count ? Int(sys.cpuLoad[c] * 100) : 0
            l.append("CORE \(c): PC=\(hex(ktext + h64() % 0x80000)), LR=\(hex(ktext + h64() % 0x80000)), FP=\(hex(0xfffffe6f00000000 + h64() % 0x10000000))  load \(load)%")
        }
        l.append("Compressor Info: \(Int(sys.memPressure * 100))% of compressed pages limit (OK) and 0% of segments limit (OK) with 0 swapfiles and OK swap space")
        l.append("Panicked task \(hex(0xfffffe1a00000000 + h64() % 0x10000000)): \(Int(rand() * 9000) + 1000) pages, \(sys.threadCount) threads: pid \(getpid()): xnu-demo")
        l.append("Panicked thread: \(hex(0xfffffe1a00000000 + h64() % 0x10000000)), backtrace: \(hex(ktext + 0x2ad000)), tid: \(Int(rand() * 900000))")
        for _ in 0..<10 {
            l.append("\t\t  lr: \(hex(ktext + h64() % 0x900000))  fp: \(hex(0xfffffe6f00000000 + h64() % 0x10000000))")
        }
        l.append("")
        l.append("Process name corresponding to current thread: \(victim)")
        l.append("Mac OS version: \(sys.osVersion)")
        l.append("System model name: \(sys.model)")
        l.append(String(format: "System uptime in nanoseconds: %.0f", sys.uptime * 1e9))
        return l
    }

    static func uuid() -> String {
        let s = UUID().uuidString
        return s
    }

    static func panic(_ text: TextLayer, _ st: Double, _ u: Uniforms) {
        text.reset()
        let maxRows = text.rows - 1
        let visible = min(Int(st * 400), lines.count)   // panics print all at once
        let start = max(0, visible - maxRows)
        for i in start..<visible {
            let line = lines[i].replacingOccurrences(of: "\t", with: "    ")
            text.put(i - start, 1, line, intensity: 0.95, maxLen: text.cols - 2)
        }
        if st > 4 && Int(st * 3) % 2 == 0 {
            text.putCentered(text.rows / 2, "  You need to restart your computer.  ", intensity: 1)
            text.putCentered(text.rows / 2 + 1, "  Hold down the Power button until it turns off. ", intensity: 0.8)
        }
    }

    // --- scene 6: credits + sine scroller -------------------------------------

    static let greetz = "   GREETZ TO: MACH  *  BSD  *  IOKIT  *  LAUNCHD  *  DTRACE  *  THE XNU TEAM  *  FARBRAUSCH  *  FUTURE CREW  *  CONSPIRACY  *  MERCURY  *  ASD  *  LOGICOMA  *  TBL  *  HAUJOBB  *  AND EVERYONE WHO EVER WROTE A SINE SCROLLER      ...  PRESS ESC TO EXIT  ...      "

    static func credits(_ text: TextLayer, _ u: inout Uniforms, _ st: Double, _ sys: SystemSnapshot) {
        text.reset()
        let lines: [(Double, String, Float)] = [
            (0.5, "X N U - D E M O", 1),
            (1.5, "a macOS / Darwin demoscene production", 0.7),
            (3.5, "code  ·  music  ·  shaders", 0.6),
            (4.5, "Claude Fable 5.1, per Mischa", 1),
            (6.5, "rendered live on \(sys.model) · \(sys.ncpu) cores · \(sys.memSize / 1_073_741_824) GB", 0.6),
            (7.5, "Darwin \(sys.osRelease) · \(xnuBuild(sys)) · \(sys.processes.count) processes", 0.6),
            (10, "thanks for watching", 0.8),
        ]
        for (i, l) in lines.enumerated() where st > l.0 {
            let fade = Float(min((st - l.0) * 2, 1))
            text.putCentered(6 + i * 2 + (i > 1 ? 1 : 0) + (i > 3 ? 1 : 0) + (i > 5 ? 1 : 0), l.1, intensity: l.2 * fade)
        }
        let row = text.rows - 8
        let pos = st * 22
        let g = Array(greetz.utf8)
        for c in 0..<text.cols {
            let idx = Int(pos) + c
            text.put(row, c, String(UnicodeScalar(g[idx % g.count])), intensity: 1)
        }
        u.scrollRow = Int32(row)
        u.scrollFrac = Float(pos - floor(pos))
    }
}
