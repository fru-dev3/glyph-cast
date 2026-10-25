import AppKit
import AVFoundation
import CoreImage

/// One stretch of the finished video and where it comes from.
struct Seg {
    enum Kind { case intro, main, outro }
    let comp: Double, dur: Double, src: Double, kind: Kind
}

struct Timeline {
    var segs: [Seg] = []
    var duration: Double { segs.last.map { $0.comp + $0.dur } ?? 0 }

    func seg(at t: Double) -> Seg? {
        // Binary search: the handler asks once per frame.
        var lo = 0, hi = segs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, s = segs[mid]
            if t < s.comp { hi = mid - 1 } else if t >= s.comp + s.dur { lo = mid + 1 } else { return s }
        }
        return t >= duration ? segs.last : segs.first
    }

    /// Where a moment of the recording lands in the finished video (nil if cut).
    func comp(forSource s: Double) -> Double? {
        segs.first { $0.kind == .main && s >= $0.src && s < $0.src + $0.dur }.map { $0.comp + s - $0.src }
    }

    func source(at t: Double) -> Double? {
        guard let s = seg(at: t), s.kind == .main else { return nil }
        return s.src + min(max(0, t - s.comp), s.dur)
    }
}

struct Built {
    let asset: AVComposition
    let video: AVVideoComposition
    let audio: AVAudioMix
    let timeline: Timeline
}

enum Composer {
    /// Wave wallpapers drawn by scripts/make_wallpapers.py, in the order the picker shows them.
    static let wallpapers: [(id: String, name: String)] = [
        ("aurora", "Aurora"), ("lagoon", "Lagoon"), ("ocean", "Ocean"), ("sunset", "Sunset"), ("dusk", "Dusk"),
        ("spectrum", "Spectrum"), ("plum", "Plum"), ("ember", "Ember"), ("glacier", "Glacier"), ("rose", "Rose"),
        ("mint", "Mint"), ("forest", "Forest"), ("midnight", "Midnight"), ("cobalt", "Cobalt"), ("graphite", "Graphite"),
        ("obsidian", "Obsidian"), ("pearl", "Pearl"), ("slate", "Slate"),
    ]

    /// In the app bundle; in a dev build, the repo's assets folder.
    static let wallpaperFolder: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("wallpapers"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/wallpapers")
    }()

    static func wallpaper(_ id: String, thumb: Bool = false) -> URL {
        wallpaperFolder.appendingPathComponent(thumb ? "thumbs/\(id).jpg" : "\(id).jpg")
    }

    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    static func outputSize(_ height: Int) -> CGSize { CGSize(width: height * 16 / 9, height: height) }

    static func build(_ p: Project, _ edit: Edit, _ style: Style, height: Int) async throws -> Built {
        let comp = AVMutableComposition()
        let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!      // cleaned voice
        let clipAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)! // intro, outro
        let ts: CMTimeScale = 48000
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }
        // A track can't take media past its end without the silence in between made explicit.
        func put(_ track: AVMutableCompositionTrack, _ r: CMTimeRange, of src: AVAssetTrack, at time: CMTime) throws {
            let end = track.timeRange.end.isValid ? track.timeRange.end : .zero
            if time > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: time)) }
            try track.insertTimeRange(r, of: src, at: time)
        }

        let screen = AVURLAsset(url: p.screen)
        guard let sv = try await screen.loadTracks(withMediaType: .video).first else { throw Fail("screen.mov has no video") }
        let voice = AVURLAsset(url: p.voice)
        let va = try await voice.loadTracks(withMediaType: .audio).first
        // The untouched mic, blended in when Studio Sound is off or below 100%.
        // (The asset is kept in a variable: a track whose asset has been released can't be inserted.)
        let original = FileManager.default.fileExists(atPath: p.original.path) ? AVURLAsset(url: p.original) : nil
        let oa = try await original?.loadTracks(withMediaType: .audio).first
        let ot = oa == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let oDur = try await oa?.load(.timeRange).end.seconds ?? 0
        let srcSize = try await sv.load(.naturalSize)
        let vDur = try await sv.load(.timeRange).end.seconds
        let ev = p.events()

        var timeline = Timeline()
        var t = 0.0

        func addClip(_ path: String, _ kind: Seg.Kind) async throws {
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            let a = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let v = try await a.loadTracks(withMediaType: .video).first else { return }
            let r = try await v.load(.timeRange)
            try vt.insertTimeRange(r, of: v, at: cm(t))
            if let au = try await a.loadTracks(withMediaType: .audio).first {
                try put(clipAudio, CMTimeRange(start: r.start, duration: min(r.duration, try await au.load(.timeRange).duration)), of: au, at: cm(t))
            }
            timeline.segs.append(Seg(comp: t, dur: r.duration.seconds, src: 0, kind: kind))
            t += r.duration.seconds
        }

        if style.intro { try await addClip(style.introPath, .intro) }

        // The recording, minus the cuts. System sound (if recorded) rides on its own track.
        var sysTrack: AVMutableCompositionTrack?
        var sysAsset: AVAssetTrack?
        var sysOffset = 0.0
        let system = FileManager.default.fileExists(atPath: p.system.path) ? AVURLAsset(url: p.system) : nil
        if let system, let s = ev.systemStart, let tr = try await system.loadTracks(withMediaType: .audio).first {
            sysTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            sysAsset = tr
            sysOffset = s - ev.videoStart
        }
        var boundaries: [Double] = []
        for k in edit.keeps(style, p.energy()) {
            let a = k.lowerBound, b = min(k.upperBound, vDur)
            guard b - a > 0.04 else { continue }
            try vt.insertTimeRange(CMTimeRange(start: cm(a), end: cm(b)), of: sv, at: cm(t))
            if let va { try put(at, CMTimeRange(start: cm(a), end: cm(b)), of: va, at: cm(t)) }
            if let oa, let ot, oDur > a { try put(ot, CMTimeRange(start: cm(a), end: cm(min(b, oDur))), of: oa, at: cm(t)) }
            if let sysTrack, let sysAsset {
                let sa = max(0, a - sysOffset), sb = b - sysOffset
                if sb > sa { try put(sysTrack, CMTimeRange(start: cm(sa), end: cm(sb)), of: sysAsset, at: cm(t + (sa - (a - sysOffset)))) }
            }
            if timeline.segs.last?.kind == .main { boundaries.append(t) }
            timeline.segs.append(Seg(comp: t, dur: b - a, src: a, kind: .main))
            t += b - a
        }

        if style.outro { try await addClip(style.outroPath, .outro) }

        // A 12 ms dip at every cut, so joins never click.
        let mix = AVMutableAudioMix()
        let studio = Float(edit.studioSound ? edit.studioAmount : 0)
        func params(_ track: AVMutableCompositionTrack, _ v: Float) -> AVMutableAudioMixInputParameters {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(v, at: .zero)
            for b in boundaries {
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: cm(b - 0.012), end: cm(b)))
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: cm(b), end: cm(b + 0.012)))
            }
            return p
        }
        mix.inputParameters = [params(at, ot == nil ? 1 : studio)] + (ot.map { [params($0, 1 - studio)] } ?? [])

        let out = outputSize(height)
        let renderer = FrameRenderer(style: style, out: out, source: srcSize, events: ev, duration: edit.duration, timeline: timeline)
        let vc = try await AVMutableVideoComposition.videoComposition(with: comp) { request in
            let img = renderer.render(request.sourceImage, at: request.compositionTime.seconds)
            request.finish(with: img, context: nil)
        }
        vc.renderSize = out
        vc.frameDuration = CMTime(value: 1, timescale: 60)
        return Built(asset: comp, video: vc, audio: mix, timeline: timeline)
    }

    static func export(_ p: Project, _ edit: Edit, _ style: Style, progress: @escaping (Double) -> Void) async throws -> URL {
        let built = try await build(p, edit, style, height: style.resolution)
        let folder = URL(fileURLWithPath: style.exportFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(p.name).mp4")
        try? FileManager.default.removeItem(at: url)
        try await encode(built, to: url, height: style.resolution, progress: progress)
        progress(1)
        try srt(edit, style, built.timeline).write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        return url
    }

    /// Reader into writer rather than an export preset, to set the quality: H.264 High at YouTube's
    /// recommended 60 fps bitrates, and 192 kbps stereo AAC (the presets give about 87 kbps mono).
    static func encode(_ built: Built, to url: URL, height: Int, progress: @escaping (Double) -> Void) async throws {
        let size = outputSize(height)
        let bitrate = height >= 2160 ? 45_000_000 : height >= 1440 ? 24_000_000 : 12_000_000
        let reader = try AVAssetReader(asset: built.asset)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.asset.loadTracks(withMediaType: .video),
                                                       videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = built.video
        reader.add(vOut)
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                                  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let aOut = AVAssetReaderAudioMixOutput(audioTracks: try await built.asset.loadTracks(withMediaType: .audio), audioSettings: pcm)
        aOut.audioMix = built.audio
        reader.add(aOut)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        writer.add(vIn)
        writer.add(aIn)
        guard reader.startReading() else { throw reader.error ?? Fail("Could not read the edit") }
        guard writer.startWriting() else { throw writer.error ?? Fail("Could not write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)

        let total = max(0.1, built.timeline.duration)
        async let video: Void = pump(vOut, into: vIn, label: "video", fps: 60, until: total) { progress(min(0.99, $0 / total)) }
        async let audio: Void = pump(aOut, into: aIn, label: "audio") { _ in }
        _ = await (video, audio)

        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? Fail("Reading the edit failed") }
        writer.endSession(atSourceTime: CMTime(seconds: total, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Fail("Writing \(url.lastPathComponent) failed") }
    }

    /// Moves samples from reader to writer. With `fps`, video comes out at a constant frame rate:
    /// the composition only hands over a frame when the picture changes, so a held frame is repeated
    /// through still stretches and up to `until`, rather than left for the writer to stretch.
    private static func pump(_ out: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                             fps: Double? = nil, until end: Double = 0, time: @escaping (Double) -> Void) async {
        let queue = DispatchQueue(label: "capture.export.\(label)")
        let p = Pump(out: out, input: input, step: fps.map { 1 / $0 }, end: end, time: time)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { p.run { done.resume() } }
        }
    }

    /// The state of one reader-to-writer pump; only ever touched on its own queue.
    private final class Pump: @unchecked Sendable {
        let out: AVAssetReaderOutput, input: AVAssetWriterInput, step: Double?, end: Double, time: (Double) -> Void
        var pending: [CMSampleBuffer] = []
        var prev: CMSampleBuffer?
        var next = 0.0
        var drained = false, finished = false

        init(out: AVAssetReaderOutput, input: AVAssetWriterInput, step: Double?, end: Double, time: @escaping (Double) -> Void) {
            self.out = out; self.input = input; self.step = step; self.end = end; self.time = time
        }

        func run(_ done: () -> Void) {
            while input.isReadyForMoreMediaData && !finished {
                if pending.isEmpty && !drained { refill(); continue }
                guard !pending.isEmpty, input.append(pending[0]) else {
                    finished = true
                    input.markAsFinished()
                    done()
                    return
                }
                time(CMSampleBufferGetPresentationTimeStamp(pending.removeFirst()).seconds)
            }
        }

        private func refill() {
            let sb = out.copyNextSampleBuffer()
            guard let step else { if let sb { pending.append(sb) } else { drained = true }; return }
            let t = sb.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? end
            if let p = prev {
                while next + step / 2 < t, let c = copy(p, at: next, step) { pending.append(c); next += step }
            }
            if let sb, let c = copy(sb, at: max(t, next), step) { pending.append(c); prev = sb; next = max(t, next) + step }
            if sb == nil { drained = true }
        }

        private func copy(_ sb: CMSampleBuffer, at t: Double, _ step: Double) -> CMSampleBuffer? {
            var timing = CMSampleTimingInfo(duration: CMTime(seconds: step, preferredTimescale: 6000),
                                            presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 6000), decodeTimeStamp: .invalid)
            var c: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &c)
            return c
        }
    }

    /// Captions for the kept words, timed to the finished video.
    static func srt(_ edit: Edit, _ style: Style, _ tl: Timeline) -> String {
        var lines: [(Double, Double, String)] = []
        var cur: [String] = [], start = 0.0, end = 0.0
        func flush() {
            if !cur.isEmpty { lines.append((start, end, cur.joined(separator: " "))) }
            cur = []
        }
        for w in edit.words where !edit.isCut(w, style) {
            guard let c = tl.comp(forSource: w.start) else { continue }
            if cur.isEmpty { start = c }
            if !cur.isEmpty && (c - end > 1.0 || c - start > 3.5) { flush(); start = c }
            cur.append(w.text)
            end = c + (w.end - w.start)
            if cur.count >= 8 || w.text.hasSuffix(".") || w.text.hasSuffix("?") || w.text.hasSuffix("!") { flush() }
        }
        flush()
        func ts(_ s: Double) -> String {
            let ms = Int((s * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return lines.enumerated().map { "\($0.offset + 1)\n\(ts($0.element.0)) --> \(ts($0.element.1))\n\($0.element.2)\n" }.joined(separator: "\n")
    }
}

/// Draws one output frame: background, soft shadow, the screen with rounded corners,
/// zoomed toward clicks, plus a ring where each click lands. Read-only after init,
/// so AVFoundation may call it from any thread.
final class FrameRenderer: @unchecked Sendable {
    let out: CGSize, rect: CGRect, src: CGSize
    let plate: CIImage, backdrop: CIImage, mask: CIImage, ring: CIImage
    let zoom: ZoomTrack
    let clicks: [[Double]]
    let style: Style
    let timeline: Timeline

    init(style: Style, out: CGSize, source: CGSize, events: EventsLog, duration: Double, timeline: Timeline) {
        self.style = style; self.out = out; self.src = source; self.timeline = timeline
        clicks = style.clickRings ? events.clicks : []
        zoom = ZoomTrack(events: events, duration: duration, amount: style.autoZoom ? style.zoomAmount : 1)

        let pad = (style.background == "none" ? 0 : style.padding) * out.width
        let avail = CGSize(width: out.width - 2 * pad, height: out.height - 2 * pad)
        let aspect = source.width / max(1, source.height)
        var size = avail.width / avail.height > aspect ? CGSize(width: avail.height * aspect, height: avail.height) : CGSize(width: avail.width, height: avail.width / aspect)
        size = CGSize(width: size.width.rounded(), height: size.height.rounded())
        rect = CGRect(x: ((out.width - size.width) / 2).rounded(), y: ((out.height - size.height) / 2).rounded(), width: size.width, height: size.height)

        let full = CGRect(origin: .zero, size: out)
        let bg = FrameRenderer.background(style, out)
        backdrop = FrameRenderer.bake(bg, full)
        let radius = style.background == "none" ? 0 : style.radius * out.width, box = rect
        let shape = { (color: CIColor) in
            CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: box), "inputRadius": radius, "inputColor": color])!.outputImage!
        }
        mask = FrameRenderer.bake(shape(.white).composited(over: CIImage(color: .black).cropped(to: full)), full)
        var p = bg
        if style.shadow && pad > 0 {
            let shadow = shape(CIColor(red: 0, green: 0, blue: 0, alpha: 0.55))
                .applyingGaussianBlur(sigma: out.width * 0.012)
                .transformed(by: CGAffineTransform(translationX: 0, y: -out.height * 0.01))
            p = shadow.composited(over: p)
        }
        plate = FrameRenderer.bake(p, full)
        ring = FrameRenderer.ringImage(radius: out.height * 0.03)
    }

    func render(_ source: CIImage, at t: Double) -> CIImage {
        let full = CGRect(origin: .zero, size: out)
        guard let seg = timeline.seg(at: t) else { return backdrop }
        if seg.kind != .main { return fit(source).composited(over: backdrop).cropped(to: full) }

        let s = seg.src + min(max(0, t - seg.comp), seg.dur)
        let (z, u, v) = zoom.sample(s)
        let e = source.extent
        let sw = e.width, sh = e.height
        // The point of the source that sits at the centre of the frame.
        let hw = sw / (2 * z), hh = sh / (2 * z)
        let cx = e.minX + min(max(u * sw, hw), sw - hw)
        let cy = e.minY + min(max((1 - v) * sh, hh), sh - hh)
        let k = rect.width / sw * z
        var img = source
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: k, y: k).translatedBy(x: -cx, y: -cy)
        if k < 1 {
            // Lanczos keeps small text sharp when shrinking a Retina capture.
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
            transform = CGAffineTransform(translationX: rect.midX - cx * k, y: rect.midY - cy * k)
        }
        img = img.transformed(by: transform).cropped(to: rect)
        var frame = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: plate, kCIInputMaskImageKey: mask])

        for c in clicks where s >= c[0] && s < c[0] + 0.5 {
            let prog = (s - c[0]) / 0.5
            let px = CGPoint(x: e.minX + c[1] * sw, y: e.minY + (1 - c[2]) * sh).applying(CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: rect.width / sw * z, y: rect.width / sw * z).translatedBy(x: -cx, y: -cy))
            guard rect.contains(px) else { continue }
            let scale = 0.5 + 0.8 * prog
            let r = ring.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = r.transformed(by: CGAffineTransform(translationX: px.x - r.extent.midX, y: px.y - r.extent.midY))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - prog)])
            frame = placed.composited(over: frame)
        }
        return frame.cropped(to: full)
    }

    private func fit(_ img: CIImage) -> CIImage {
        let e = img.extent
        let k = min(out.width / e.width, out.height / e.height)
        return img.transformed(by: CGAffineTransform(translationX: (out.width - e.width * k) / 2, y: (out.height - e.height * k) / 2)
            .scaledBy(x: k, y: k).translatedBy(x: -e.minX, y: -e.minY))
    }

    static func background(_ style: Style, _ out: CGSize) -> CIImage {
        let full = CGRect(origin: .zero, size: out)
        if style.background == "none" { return CIImage(color: .black).cropped(to: full) }
        var path = style.background == "image" ? style.imagePath : Composer.wallpaper(style.background).path
        if style.background == "wallpaper", let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) { path = url.path }
        if !path.isEmpty, let img = loadImage(path) {
            let e = img.extent, k = max(out.width / e.width, out.height / e.height)
            return img.transformed(by: CGAffineTransform(translationX: (out.width - e.width * k) / 2, y: (out.height - e.height * k) / 2)
                .scaledBy(x: k, y: k).translatedBy(x: -e.minX, y: -e.minY)).cropped(to: full)
        }
        return CIImage(color: CIColor(red: 0.05, green: 0.06, blue: 0.08)).cropped(to: full)
    }

    static func loadImage(_ path: String) -> CIImage? {
        if let i = CIImage(contentsOf: URL(fileURLWithPath: path)) { return i }
        // A folder wallpaper (dynamic) or anything else NSImage can read.
        guard let ns = NSImage(contentsOfFile: path), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Render once to a bitmap so blurs and gradients aren't recomputed every frame.
    static func bake(_ img: CIImage, _ rect: CGRect) -> CIImage {
        guard let cg = Composer.context.createCGImage(img, from: rect) else { return img }
        return CIImage(cgImage: cg)
    }

    static func ringImage(radius r: CGFloat) -> CIImage {
        let size = Int(r * 2 + 16)
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let box = CGRect(x: 8, y: 8, width: r * 2, height: r * 2)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 0.25))
        ctx.fillEllipse(in: box)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(max(3, r * 0.12))
        ctx.strokeEllipse(in: box.insetBy(dx: r * 0.06, dy: r * 0.06))
        return CIImage(cgImage: ctx.makeImage()!)
    }
}

/// Zoom level and focus point over the recording, sampled 30 times a second.
/// Zooms in around each burst of clicks, follows the (smoothed) cursor while in, eases out after.
struct ZoomTrack {
    static let fps = 30.0
    var z: [Double] = [], u: [Double] = [], v: [Double] = []

    init(events: EventsLog, duration: Double, amount: Double) {
        let n = max(1, Int(duration * ZoomTrack.fps) + 2)
        // Cursor, sample-and-hold, then smoothed both ways (no lag).
        var cu = [Double](repeating: 0.5, count: n), cv = [Double](repeating: 0.5, count: n)
        var j = 0, lu = 0.5, lv = 0.5
        for i in 0..<n {
            let t = Double(i) / ZoomTrack.fps
            while j < events.cursor.count && events.cursor[j][0] <= t { lu = events.cursor[j][1]; lv = events.cursor[j][2]; j += 1 }
            cu[i] = min(max(lu, 0), 1); cv[i] = min(max(lv, 0), 1)
        }
        let a = 1 - exp(-1 / (ZoomTrack.fps * 0.3))
        func smooth(_ x: inout [Double]) {
            for i in 1..<x.count { x[i] = x[i - 1] + a * (x[i] - x[i - 1]) }
            for i in stride(from: x.count - 2, through: 0, by: -1) { x[i] = x[i + 1] + a * (x[i] - x[i + 1]) }
        }
        smooth(&cu); smooth(&cv)

        // Click bursts: clicks less than 3 s apart belong together.
        var windows: [(Double, Double)] = []
        for c in events.clicks.map({ $0[0] }).sorted() {
            if let last = windows.last, c - last.1 < 3.0 { windows[windows.count - 1].1 = c }
            else { windows.append((c, c)) }
        }
        var zz = [Double](repeating: 1, count: n)
        if amount > 1.01 {
            for (s, e) in windows {
                let a = s - 0.3, b = e + 1.8      // arrive just before the click, linger after
                for i in 0..<n {
                    let t = Double(i) / ZoomTrack.fps
                    var k = 0.0
                    if t >= a - 0.6 && t < a { k = ZoomTrack.ease((t - (a - 0.6)) / 0.6) }
                    else if t >= a && t <= b { k = 1 }
                    else if t > b && t < b + 0.8 { k = 1 - ZoomTrack.ease((t - b) / 0.8) }
                    zz[i] = max(zz[i], 1 + (amount - 1) * k)
                }
            }
        }
        z = zz; u = cu; v = cv
    }

    static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    func sample(_ t: Double) -> (Double, Double, Double) {
        let f = max(0, t * ZoomTrack.fps)
        let i = min(Int(f), z.count - 1), i2 = min(i + 1, z.count - 1), w = f - Double(i)
        func lerp(_ a: [Double]) -> Double { a[i] + (a[i2] - a[i]) * min(1, w) }
        return (lerp(z), lerp(u), lerp(v))
    }
}
