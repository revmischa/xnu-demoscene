import AVFoundation
import CoreVideo
import Metal

/// Offline render of the whole demo to an HEVC .mov: the clock is stepped by hand, the synth
/// renders exactly one frame's worth of samples before each video frame (so beat triggers line
/// up), and audio and video are appended to AVAssetWriter in lockstep. (In non-realtime mode
/// the writer interleaves tracks, so feeding all audio at the end would stall the video input.)
func renderVideo(to path: String, width: Int, height: Int, fps: Int, seconds: Double?) {
    let device = MTLCreateSystemDefaultDevice()!
    let renderer = Renderer(device: device, colorFormat: .bgra8Unorm)
    renderer.resize(CGSize(width: width, height: height), cap: false)
    SystemInfo.shared.start()

    let sr = 48000.0
    let synth = Synth(sampleRate: sr)
    let total = seconds ?? (demoLength + 1.0)
    let frames = Int(total * Double(fps))
    let spf = Int(sr) / fps
    var left = [Float](repeating: 0, count: spf), right = [Float](repeating: 0, count: spf)
    var interleaved = [Float](repeating: 0, count: spf * 2)
    var asbd = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var audioFormat: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)

    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000, AVVideoExpectedSourceFrameRateKey: fps,
                                          AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoAllowFrameReorderingKey: true],
    ])
    vin.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 320_000,
    ])
    writer.add(vin); writer.add(ain)
    guard writer.startWriting() else { fputs("writer failed: \(String(describing: writer.error))\n", stderr); exit(1) }
    writer.startSession(atSourceTime: .zero)

    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    let start = Date()
    for i in 0..<frames {
        let t = Double(i) / Double(fps)
        DemoClock.override = t
        synth.render(frames: spf, left: &left, right: &right)
        for k in 0..<spf { interleaved[k * 2] = left[k]; interleaved[k * 2 + 1] = right[k] }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sr)), presentationTimeStamp: CMTime(value: CMTimeValue(i * spf), timescale: CMTimeScale(sr)), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: audioFormat, sampleCount: spf, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        interleaved.withUnsafeMutableBytes { p in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(p.count), mData: p.baseAddress))
            CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: &abl)
        }
        while !ain.isReadyForMoreMediaData {
            if writer.status == .failed { fputs("writer failed: \(String(describing: writer.error))\n", stderr); exit(1) }
            usleep(500)
        }
        ain.append(sb!)
        renderer.update(time: t)
        renderer.text.upload(to: renderer.textTex)

        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        var cvtex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache!, pb!, nil, .bgra8Unorm, width, height, 0, &cvtex)
        let target = CVMetalTextureGetTexture(cvtex!)!
        let cmd = renderer.queue.makeCommandBuffer()!
        renderer.render(to: target, cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        while !vin.isReadyForMoreMediaData {
            if writer.status == .failed { fputs("writer failed: \(String(describing: writer.error))\n", stderr); exit(1) }
            usleep(500)
        }
        if !adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) {
            fputs("append failed at frame \(i): \(String(describing: writer.error))\n", stderr); exit(1)
        }
        if i % (fps * 5) == 0 {
            let el = Date().timeIntervalSince(start)
            fputs(String(format: "video %5.1f / %.1f s  (%.0f fps render, eta %.0f s)\n", t, total, Double(i + 1) / max(el, 0.001), el / Double(i + 1) * Double(frames - i)), stderr)
        }
    }
    vin.markAsFinished()
    ain.markAsFinished()
    CVMetalTextureCacheFlush(cache!, 0)
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    if writer.status != .completed { fputs("finish failed: \(String(describing: writer.error))\n", stderr); exit(1) }
    fputs("wrote \(path) (\(frames) frames, \(width)x\(height)@\(fps))\n", stderr)
}
