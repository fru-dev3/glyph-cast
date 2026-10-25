import AppKit
import AVFoundation
import ScreenCaptureKit
import QuartzCore

/// Records one display to screen.mov (HEVC), the microphone to mic.caf and, if asked,
/// system sound to system.caf. All three share the host clock, so the start times saved
/// in events.json line them up exactly. Cursor, clicks and screen activity are logged too.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "capture.recorder")
    private var stream: SCStream?
    private var folder: URL!
    private var log = EventsLog()

    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var lastFrame: CMSampleBuffer?
    private var micWriter: AVAssetWriter?, micInput: AVAssetWriterInput?
    private var sysWriter: AVAssetWriter?, sysInput: AVAssetWriterInput?

    private var mouseTimer: Timer?
    private var clickMonitor: Any?
    private var screenFrame = CGRect.zero
    private(set) var failure: String?
    var onFailure: ((String) -> Void)?
    /// The mic's loudness, 0...1, about 20 times a second (called on the recorder's queue).
    var onLevel: ((Float) -> Void)?

    // Pause: samples are dropped while paused, and everything after is shifted back by the time
    // spent paused, so the files play straight through with no gap. (On `queue`.)
    private var paused = false
    private var pausedAt = CMTime.invalid
    private var pausedTotal = CMTime.zero
    private var micFile = "mic.caf"
    private var levelSum: Float = 0, levelCount = 0, levelPeak: Float = 0

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    func start(displayID: CGDirectDisplayID?, micID: String?, systemAudio: Bool, folder: URL) async throws {
        self.folder = folder
        log = EventsLog()
        failure = nil
        queue.sync { paused = false; pausedAt = .invalid; pausedTotal = .zero; micFile = "mic.caf" }
        // All apps, not only those on screen: Capture's window is hidden by now, and an app with nothing
        // on screen is missing from the on-screen list, so it would not be left out of the recording.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw Fail("No display to record") }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
        let scale = screen?.backingScaleFactor ?? 2
        screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let w = Int(Double(display.width) * scale) / 2 * 2, h = Int(Double(display.height) * scale) / 2 * 2
        log.pixelWidth = Double(w); log.pixelHeight = Double(h)

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 8
        cfg.capturesAudio = systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        if let micID {
            cfg.captureMicrophone = true
            cfg.microphoneCaptureDeviceID = micID
        }

        let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("screen.mov"), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(12_000_000, w * h * 4),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Fail("Could not start the video file") }
        videoWriter = writer
        videoInput = input

        config = cfg
        hasMicOutput = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if micID != nil { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue); hasMicOutput = true }
        if systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
        await MainActor.run { startMouseLog() }
    }

    private var oldMicWriters: [AVAssetWriter] = []

    /// Switch microphones mid-recording: the old mic's file is closed and the new one gets its own,
    /// which processing lines up on the timeline.
    func switchMicrophone(_ id: String) async throws {
        guard let stream else { return }
        queue.sync {
            if let w = micWriter { micInput?.markAsFinished(); oldMicWriters.append(w) }
            micWriter = nil; micInput = nil
            micFile = "mic-\(log.micSegments.count + 1).caf"
        }
        let cfg = SCStreamConfiguration()
        cfg.captureMicrophone = true
        cfg.microphoneCaptureDeviceID = id
        try await stream.updateConfiguration(currentConfig(with: cfg))
        if !hasMicOutput { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue); hasMicOutput = true }
    }

    private var config: SCStreamConfiguration?
    private var hasMicOutput = false

    /// The running configuration with the microphone fields replaced.
    private func currentConfig(with mic: SCStreamConfiguration) -> SCStreamConfiguration {
        let c = config ?? mic
        c.captureMicrophone = mic.captureMicrophone
        c.microphoneCaptureDeviceID = mic.microphoneCaptureDeviceID
        return c
    }

    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    func pause() {
        queue.sync { if !paused { paused = true; pausedAt = Recorder.hostNow } }
    }

    func resume() {
        queue.sync {
            guard paused else { return }
            pausedTotal = pausedTotal + (Recorder.hostNow - pausedAt)
            paused = false
        }
    }

    /// A buffer moved back by the time spent paused, or nil while paused.
    private func shifted(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        if paused { return nil }
        if pausedTotal == .zero { return sb }
        let n = CMSampleBufferGetNumSamples(sb)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: timing.count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - pausedTotal
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - pausedTotal }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: n > 0 ? timing.count : 0, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    func stop() async throws -> EventsLog {
        await MainActor.run { stopMouseLog() }
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        let writers: [AVAssetWriter] = queue.sync {
            // The end of the recording, on the shifted clock: time spent paused doesn't count.
            let now = Recorder.hostNow - pausedTotal - (paused ? Recorder.hostNow - pausedAt : .zero)
            // A still screen sends no frames, so repeat the last one up to the moment we stopped:
            // the video then runs as long as the voice.
            // It gets one frame's duration and the file ends exactly at `now`; without that the writer
            // guesses the duration from the gap before it, and a still screen came out twice as long.
            let frame = CMTime(value: 1, timescale: 60)
            if let last = lastFrame, let input = videoInput, now - frame > CMSampleBufferGetPresentationTimeStamp(last) {
                var timing = CMSampleTimingInfo(duration: frame, presentationTimeStamp: now - frame, decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
                if let copy, input.isReadyForMoreMediaData { input.append(copy) }
            }
            if lastFrame != nil { videoWriter?.endSession(atSourceTime: now) }
            log.duration = now.seconds - log.videoStart
            videoInput?.markAsFinished(); micInput?.markAsFinished(); sysInput?.markAsFinished()
            return ([videoWriter, micWriter, sysWriter].compactMap { $0 }) + oldMicWriters
        }
        for w in writers where w.status == .writing { await w.finishWriting() }
        if lastFrame == nil { throw Fail("No video frames arrived. Check Screen Recording permission for Glyph Cast in System Settings.") }
        if let e = videoWriter?.error { throw e }
        try JSONEncoder().encode(log).write(to: folder.appendingPathComponent("events.json"))
        videoWriter = nil; micWriter = nil; sysWriter = nil; lastFrame = nil; oldMicWriters = []
        return log
    }

    // MARK: stream output (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if type == .microphone { meter(sb) }
        guard let sb = shifted(sb) else { return }
        switch type {
        case .screen: video(sb)
        case .microphone:
            var start: Double?
            let first = micWriter == nil
            audio(sb, writer: &micWriter, input: &micInput, file: micFile, start: &start)
            if first, let start {
                if log.micStart == nil { log.micStart = start }
                log.micSegments.append(MicSegment(file: micFile, start: start))
            }
        case .audio: audio(sb, writer: &sysWriter, input: &sysInput, file: "system.caf", start: &log.systemStart)
        @unknown default: break
        }
    }

    private func video(_ sb: CMSampleBuffer) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let writer = videoWriter, let input = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if lastFrame == nil {
            writer.startSession(atSourceTime: pts)
            log.videoStart = pts.seconds
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
        lastFrame = sb

        // How much of the screen changed: tells a thinking pause from silent screen work.
        if let rects = info[.dirtyRects] as? [NSDictionary], let scale = info[.scaleFactor] as? Double, log.pixelWidth > 0 {
            let area = rects.compactMap { CGRect(dictionaryRepresentation: $0) }.reduce(0.0) { $0 + Double($1.width * $1.height) }
            let frac = area * scale * scale / (log.pixelWidth * log.pixelHeight)
            if frac > 0.0005 { log.activity.append([round3(pts.seconds - log.videoStart), round3(min(1, frac) * 1000) / 1000]) }
        }
    }

    private func audio(_ sb: CMSampleBuffer, writer: inout AVAssetWriter?, input: inout AVAssetWriterInput?, file: String, start: inout Double?) {
        if writer == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sb),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
                  let w = try? AVAssetWriter(outputURL: folder.appendingPathComponent(file), fileType: .caf) else { return }
            // Lossless 32-bit float at the device's own rate and channel count.
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { return }
            w.add(i)
            guard w.startWriting() else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            w.startSession(atSourceTime: pts)
            start = pts.seconds
            writer = w; input = i
        }
        if input?.isReadyForMoreMediaData == true { input?.append(sb) }
    }

    /// Loudness of the mic for the recording pill (works while paused too, so you can check the mic).
    private func meter(_ sb: CMSampleBuffer) {
        guard let onLevel, let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return }
        // All the samples, whatever the channel layout: loudness doesn't care which channel.
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let ptr, CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) else { return }
        let n = length / 4
        let f = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
        for i in 0..<n { levelSum += f[i] * f[i] }
        levelCount += n
        if levelCount >= Int(asbd.mSampleRate / 20) {
            let rms = sqrt(levelSum / Float(levelCount))
            levelSum = 0; levelCount = 0
            onLevel(max(0, min(1, (20 * log10(max(rms, 1e-6)) + 60) / 50)))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        failure = error.localizedDescription
        onFailure?(error.localizedDescription)
    }

    // MARK: mouse (main thread)

    private func startMouseLog() {
        var last = CGPoint(x: -1, y: -1)
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            guard p != last else { return }
            last = p
            self.logPoint(p, into: \.cursor)
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.logPoint(NSEvent.mouseLocation, into: \.clicks)
        }
    }

    private func logPoint(_ p: CGPoint, into path: WritableKeyPath<EventsLog, [[Double]]>) {
        let t = CACurrentMediaTime()   // same host clock as the sample buffers
        let u = (p.x - screenFrame.minX) / screenFrame.width
        let v = (screenFrame.maxY - p.y) / screenFrame.height
        queue.async {
            guard self.log.videoStart > 0, !self.paused else { return }
            self.log[keyPath: path].append([self.round3(t - self.pausedTotal.seconds - self.log.videoStart), self.round3(u), self.round3(v)])
        }
    }

    private func stopMouseLog() {
        mouseTimer?.invalidate(); mouseTimer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
