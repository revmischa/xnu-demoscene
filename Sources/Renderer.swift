import MetalKit
import simd

/// Mirrors `Uniforms` in Shaders.metal. Field order and alignment must match.
struct Uniforms {
    var cpu: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var resolution = SIMD2<Float>(1, 1)
    var time: Float = 0
    var beat: Float = 0
    var sceneTime: Float = 0
    var sceneProgress: Float = 0
    var kick: Float = 0
    var snare: Float = 0
    var hat: Float = 0
    var bass: Float = 0
    var lead: Float = 0
    var leadNote: Float = 0
    var memPressure: Float = 0
    var loadAvg: Float = 0
    var procCount: Float = 0
    var uptime: Float = 0
    var transition: Float = 1
    var textAlpha: Float = 1
    var scrollFrac: Float = 0
    var scene: Int32 = 0
    var cols: Int32 = 0
    var rows: Int32 = 0
    var ncpu: Int32 = 1
    var scrollRow: Int32 = -1
}

/// Scene timeline in bars (128 BPM, 1.875 s/bar). The shader switches on `scene`.
struct SceneDef { let scene: Int32; let startBar: Double; let endBar: Double; let name: String }
let timeline: [SceneDef] = [
    SceneDef(scene: 0, startBar: 0, endBar: 16, name: "boot"),
    SceneDef(scene: 1, startBar: 16, endBar: 32, name: "mach ports"),
    SceneDef(scene: 2, startBar: 32, endBar: 48, name: "plasma / proc rain"),
    SceneDef(scene: 3, startBar: 48, endBar: 64, name: "tunnel"),
    SceneDef(scene: 4, startBar: 64, endBar: 72, name: "kernel panic"),
    SceneDef(scene: 5, startBar: 72, endBar: 88, name: "xnu finale"),
    SceneDef(scene: 6, startBar: 88, endBar: 100, name: "credits"),
]

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var scenePipeline: MTLRenderPipelineState!
    var brightPipeline: MTLRenderPipelineState!
    var blurPipeline: MTLRenderPipelineState!
    var postPipeline: MTLRenderPipelineState!
    var sceneTex: MTLTexture?
    var bloomA: MTLTexture?
    var bloomB: MTLTexture?
    let sampler: MTLSamplerState
    let text: TextLayer
    let atlas: MTLTexture
    var textTex: MTLTexture
    var uniforms = Uniforms()
    var lastScene: Int32 = -1
    var ended = false
    var frames = 0
    var fpsTime = 0.0

    init(view: MTKView) {
        device = view.device!
        queue = device.makeCommandQueue()!
        text = TextLayer(cols: 128, rows: 40)
        atlas = GlyphAtlas.make(device: device)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: text.cols, height: text.rows, mipmapped: false)
        td.usage = .shaderRead
        textTex = device.makeTexture(descriptor: td)!
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        super.init()

        let opts = MTLCompileOptions()
        opts.fastMathEnabled = true
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderSource, options: opts) } catch {
            fputs("shader compile failed:\n\(error)\n", stderr); exit(1)
        }
        func pipeline(_ frag: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            d.fragmentFunction = library.makeFunction(name: frag)
            d.colorAttachments[0].pixelFormat = format
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        scenePipeline = pipeline("sceneFragment", .rgba16Float)
        brightPipeline = pipeline("brightFragment", .rgba16Float)
        blurPipeline = pipeline("blurFragment", .rgba16Float)
        postPipeline = pipeline("postFragment", view.colorPixelFormat)

        view.delegate = self
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        mtkView(view, drawableSizeWillChange: view.drawableSize)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Internal render resolution capped at ~1080p; the post pass upscales. Raymarching 4K is a waste.
        let scale = min(1, 1080 / max(size.height, 1))
        let w = max(Int(size.width * scale), 16), h = max(Int(size.height * scale), 16)
        func tex(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        sceneTex = tex(w, h)
        bloomA = tex(w / 4, h / 4)
        bloomB = tex(w / 4, h / 4)
    }

    func draw(in view: MTKView) {
        guard let sceneTex, let bloomA, let bloomB, let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }
        let t = DemoClock.now()
        if t >= demoLength + 1.0 && !ended {
            ended = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        update(time: t)
        text.upload(to: textTex)

        let cmd = queue.makeCommandBuffer()!
        func pass(_ target: MTLTexture, _ pipe: MTLRenderPipelineState, _ textures: [MTLTexture], _ extra: SIMD2<Float> = .zero) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            encode(cmd.makeRenderCommandEncoder(descriptor: d)!, pipe, textures, extra)
        }
        pass(sceneTex, scenePipeline, [atlas, textTex])
        pass(bloomA, brightPipeline, [sceneTex])
        pass(bloomB, blurPipeline, [bloomA], SIMD2<Float>(1, 0))
        pass(bloomA, blurPipeline, [bloomB], SIMD2<Float>(0, 1))
        encode(cmd.makeRenderCommandEncoder(descriptor: rpd)!, postPipeline, [sceneTex, bloomA], .zero)
        cmd.present(drawable)
        if let shotPath, t > startAt + 1.5 { saveShot(cmd, drawable.texture, shotPath) } else { cmd.commit() }
    }

    private func saveShot(_ cmd: MTLCommandBuffer, _ src: MTLTexture, _ path: String) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .shared
        let tex = device.makeTexture(descriptor: d)!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        encode(cmd.makeRenderCommandEncoder(descriptor: rp)!, postPipeline, [sceneTex!, bloomA!], .zero)
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: src.width * src.height * 4)
        tex.getBytes(&bytes, bytesPerRow: src.width * 4, from: MTLRegionMake2D(0, 0, src.width, src.height), mipmapLevel: 0)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2); bytes[i + 3] = 255 } // bgra -> rgba
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: src.width, pixelsHigh: src.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: src.width * 4, bitsPerPixel: 32)!
        bytes.withUnsafeBufferPointer { rep.bitmapData!.update(from: $0.baseAddress!, count: bytes.count) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        fputs("saved \(path)\n", stderr)
        exit(0)
    }

    private func encode(_ enc: MTLRenderCommandEncoder, _ pipe: MTLRenderPipelineState, _ textures: [MTLTexture], _ extra: SIMD2<Float>) {
        enc.setRenderPipelineState(pipe)
        var u = uniforms
        var e = extra
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&e, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func update(time t: Double) {
        let sys = SystemInfo.shared.snapshot
        let beat = DemoClock.beat(at: t)
        let bar = beat / 4
        let def = timeline.last(where: { bar >= $0.startBar }) ?? timeline[0]
        let secPerBar = 4 * 60 / DemoClock.bpm
        let sceneStart = def.startBar * secPerBar, sceneEnd = def.endBar * secPerBar
        let sceneTime = t - sceneStart
        let dur = sceneEnd - sceneStart
        if def.scene != lastScene { lastScene = def.scene; text.reset(); fputs("[\(String(format: "%6.2f", t))s] scene \(def.scene): \(def.name)\n", stderr) }

        var u = uniforms
        u.resolution = SIMD2<Float>(Float(sceneTex?.width ?? 1), Float(sceneTex?.height ?? 1))
        u.time = Float(t)
        u.beat = Float(beat)
        u.sceneTime = Float(sceneTime)
        u.sceneProgress = Float(min(max(sceneTime / dur, 0), 1))
        func pulse(_ at: Double, _ k: Double) -> Float { Float(exp(-max(t - at, 0) * k)) }
        u.kick = pulse(Trigger.kick, 6)
        u.snare = pulse(Trigger.snare, 8)
        u.hat = pulse(Trigger.hat, 20)
        u.bass = pulse(Trigger.bass, 10)
        u.lead = pulse(Trigger.lead, 5)
        u.leadNote = Float(Trigger.leadNote)
        u.memPressure = sys.memPressure
        u.loadAvg = sys.loadAvg
        u.procCount = Float(sys.processes.count)
        u.uptime = Float(sys.uptime)
        u.scene = def.scene
        u.cols = Int32(text.cols); u.rows = Int32(text.rows)
        u.ncpu = Int32(sys.ncpu)
        var cpu = [Float](repeating: 0, count: 16)
        for (i, l) in sys.cpuLoad.prefix(16).enumerated() { cpu[i] = l }
        u.cpu = (SIMD4(cpu[0], cpu[1], cpu[2], cpu[3]), SIMD4(cpu[4], cpu[5], cpu[6], cpu[7]),
                 SIMD4(cpu[8], cpu[9], cpu[10], cpu[11]), SIMD4(cpu[12], cpu[13], cpu[14], cpu[15]))
        // Fade in/out at scene edges; the panic scene handles its own exit dissolve.
        let fadeIn = min(sceneTime / 0.6, 1), fadeOut = def.scene == 4 ? 1 : min((dur - sceneTime) / 0.6, 1)
        u.transition = Float(max(min(fadeIn, fadeOut), 0))
        if t > demoLength { u.transition = 0 }
        u.scrollRow = -1
        u.scrollFrac = 0
        u.textAlpha = 1
        TextScenes.update(text: text, u: &u, sys: sys, t: t, sceneTime: sceneTime)
        uniforms = u

        frames += 1
        if fpsTime == 0 { fpsTime = t }
        if t - fpsTime > 5 { fputs("  \(frames / 5) fps, \(sys.processes.count) procs, load \(String(format: "%.2f", sys.loadAvg)), ports \(sys.machPorts)\n", stderr); frames = 0; fpsTime = t }
    }
}
