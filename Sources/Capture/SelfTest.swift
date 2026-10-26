import AppKit
import AVFoundation

/// `Capture --selftest`: builds a fake recording (a spoken script with "um"s, a dead pause,
/// and a pause where the screen is busy), runs the real processing and export, and checks the result.
/// `Capture --record-test 6`: records the real screen (and mic, if allowed) for 6 seconds, then the same.
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
        if !ok { failures += 1 }
    }

    static func run(_ args: [String]) async -> Bool {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-selftest-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            print("Self-test in \(dir.path)")
            unitChecks()
            if let i = args.firstIndex(of: "--record-test") {
                let secs = i + 1 < args.count ? Double(args[i + 1]) ?? 6 : 6
                try await recordTest(dir, seconds: secs)
            } else {
                try await pipelineTest(dir)
            }
        } catch {
            check(false, "no error thrown: \(error.localizedDescription)")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    static func unitChecks() {
        print("Logic")
        var ev = EventsLog()
        ev.clicks = [[10, 0.8, 0.2]]
        ev.cursor = [[0, 0.5, 0.5], [9, 0.8, 0.2]]
        let zt = ZoomTrack(events: ev, duration: 20, amount: 1.6)
        check(abs(zt.sample(10).0 - 1.6) < 0.01, "zoom is in at a click")
        check(abs(zt.sample(2).0 - 1) < 0.01 && abs(zt.sample(16).0 - 1) < 0.01, "zoom is out away from clicks")
        check(zt.sample(10).1 > 0.7, "zoom follows the cursor")

        let words: [(String, Double, Double)] = [("Hello", 0.5, 1.0), ("um,", 1.0, 1.4), ("world.", 1.4, 4.0), ("Next", 6.0, 6.5)]
        var edit = Processor.build(words: words, silences: [2.0...5.9], events: EventsLog(), duration: 8)
        check(edit.words.count == 4 && edit.fillerKind(1) == "um", "fillers are flagged")
        check(abs(edit.words[2].end - 2.0) < 0.01, "a word stretched over a pause is trimmed to the speech")
        let s = Style()
        check(edit.keeps(s).contains { $0.contains(1.2) } && edit.keeps(s).contains { $0.contains(4.5) }, "nothing is cut until you clean up")
        edit.removeFillers = true; edit.shortenPauses = true
        let keeps = edit.keeps(s)
        let kept = keeps.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        check(kept < 4.5 && kept > 2.0, "pauses and fillers are cut (kept \(String(format: "%.2f", kept)) s of 8)")
        check(!keeps.contains { $0.contains(1.2) }, "the filler itself is gone")
        let tics = Processor.build(words: [("So", 0, 0.3), ("the", 0.4, 0.6), ("the", 0.7, 0.9), ("app,", 1, 1.4), ("you", 1.5, 1.6), ("know,", 1.6, 1.8), ("like", 2, 2.2), ("works.", 2.3, 2.8)],
                                   silences: [], events: EventsLog(), duration: 3)
        check(tics.fillerKind(1) == "repeat" && tics.fillerKind(2) == nil, "a doubled word is found, and only the first goes")
        check(tics.fillerKind(4) == "tic" && tics.fillerKind(5) == "tic" && tics.fillerKind(6) == "tic" && tics.fillerKind(0) == nil, "like and you know are verbal tics")
        var t2 = tics
        t2.removeFillers = true
        check(t2.isCut(t2.words[1], s) && !t2.isCut(t2.words[6], s), "Remove filler words takes repeats by default, tics only when chosen")
        let old = try! JSONDecoder().decode(Edit.self, from: Data(#"{"duration":1,"words":[],"gaps":[]}"#.utf8))
        check(!old.removeFillers && old.studioSound && old.fillerKinds == ["um", "repeat"], "edits saved by the first version still open")
        // A real "uh" (from a recording): whisper says 1.44-1.82 but the sound runs 1.35-1.73, then "in".
        var db = [Float](repeating: -72, count: 300)
        for i in 135..<160 { db[i] = -13 }; for i in 160..<174 { db[i] = -26 }; for i in 174..<220 { db[i] = -12 }
        let cut = Energy(db: db).cleanCut(1.44, 1.82, after: 0.74, before: 1.82)
        check(abs(cut.upperBound - 1.73) < 0.03, String(format: "a filler's cut ends where its sound ends, not where whisper says (%.2f)", cut.upperBound))
        check(cut.lowerBound < 1.35 && cut.lowerBound > 0.95 && abs((1.35 - cut.lowerBound) - 0.35) < 0.03,
              String(format: "it starts before the filler's first sound and leaves a natural 0.25 s pause (%.2f)", cut.lowerBound))
        var tl = Timeline()
        tl.segs = [Seg(comp: 0, dur: 7, src: 0, kind: .intro), Seg(comp: 7, dur: 2, src: 3, kind: .main), Seg(comp: 9, dur: 1, src: 8, kind: .main)]
        check(tl.comp(forSource: 3.5) == 7.5 && tl.comp(forSource: 6) == nil && tl.source(at: 9.5) == 8.5, "timeline maps both ways")
    }

    /// A known script, so every expectation is exact.
    static func pipelineTest(_ dir: URL) async throws {
        print("Pipeline")
        let p = Project(folder: dir.appendingPathComponent("2026-01-01 10-00-00"))
        try FileManager.default.createDirectory(at: p.folder, withIntermediateDirectories: true)
        // A name sticks (title.txt), names the export safely, and clearing it brings the date back.
        let dated = p.title
        p.rename("Demo: build/run")
        check(Project(folder: p.folder).title == "Demo: build/run" && p.fileName == "Demo- build-run", "a renamed recording keeps its name and exports as \(p.fileName)")
        p.rename("  ")
        check(Project(folder: p.folder).title == dated && p.fileName == p.name, "clearing the name brings the date back")
        let aiff = dir.appendingPathComponent("v.aiff").path
        try Tools.run("/usr/bin/say", ["-v", "Samantha", "-o", aiff,
            "[[slnc 1200]] So today, um, I want to show you how this works. [[slnc 2600]] Uh, first we open the terminal. [[slnc 2200]] And then, um, we run the build. [[slnc 1500]]"])
        let voiceLen = try Processor.probeDuration(URL(fileURLWithPath: aiff))
        // Mic starts 0.25 s after the first video frame, as on a real Mac.
        try Tools.ffmpeg(["-i", aiff, "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", p.mic.path])
        let dur = voiceLen + 0.25
        try Tools.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=3024x1964:rate=30", "-t", "\(dur)", "-c:v", "hevc_videotoolbox", "-b:v", "6M", "-tag:v", "hvc1", p.screen.path])

        // Find the two long pauses in the script to place a click inside the second.
        let sil = try Processor.detectSilence(aiff).filter { $0.upperBound - $0.lowerBound > 1.8 && $0.lowerBound > 2 }
        check(sil.count >= 2, "fixture has two long pauses (\(sil.count))")
        var ev = EventsLog()
        ev.videoStart = 1000; ev.micStart = 1000.25; ev.duration = dur
        // System sound: a quiet low hum, starting with the video.
        try Tools.ffmpeg(["-f", "lavfi", "-i", "sine=f=110:r=48000", "-af", "volume=-38dB", "-t", "\(dur)", "-ac", "2", "-c:a", "pcm_f32le", p.system.path])
        ev.systemStart = 1000
        ev.pixelWidth = 3024; ev.pixelHeight = 1964
        let busyAt = (sil.count > 1 ? (sil[1].lowerBound + sil[1].upperBound) / 2 : 9) + 0.25
        ev.clicks = [[busyAt, 0.3, 0.3]]
        ev.cursor = [[0, 0.5, 0.5], [busyAt - 0.5, 0.3, 0.3]]
        try JSONEncoder().encode(ev).write(to: p.eventsURL)

        let t0 = Date()
        var edit = try await Processor.process(p) { print("    \($0)") }
        print(String(format: "    processed in %.1f s", Date().timeIntervalSince(t0)))
        let text = edit.words.map(\.text).joined(separator: " ")
        print("    transcript: \(text)")
        check(text.lowercased().contains("terminal"), "transcript has the words")
        check(edit.words.filter(\.filler).count >= 2, "fillers found (\(edit.words.filter(\.filler).map(\.text)))")
        let style = Style()
        check(!edit.isCut(edit.words.first { $0.filler }!, style), "fillers stay until Remove filler words")
        edit.removeFillers = true; edit.shortenPauses = true
        let longGaps = edit.gaps.filter { !$0.head && !$0.tail && $0.length > 1.5 }
        check(longGaps.contains { !$0.screenBusy && edit.isCut($0, style) }, "a dead pause is cut")
        check(longGaps.contains { $0.screenBusy && !edit.isCut($0, style) }, "a pause with a click in it is kept")
        check(edit.gaps.first?.head == true && edit.isCut(edit.gaps[0], style), "dead air at the start is cut")

        let lufs = try loudness(p.voice.path)
        check(abs(lufs + 14) < 1.5, String(format: "voice is at YouTube loudness (%.1f LUFS)", lufs))
        let lufsO = try loudness(p.original.path)
        check(abs(lufsO + 14) < 1.5, String(format: "the original mic for the Studio Sound blend is at the same loudness (%.1f LUFS)", lufsO))
        var half = edit
        half.studioAmount = 0.5
        let mixed = try await Composer.build(p, half, style, height: 360).audio.inputParameters
        var v0: Float = -1, v1: Float = -1, end: Float = 0, tr = CMTimeRange()
        _ = mixed.first?.getVolumeRamp(for: .zero, startVolume: &v0, endVolume: &end, timeRange: &tr)
        _ = mixed.last?.getVolumeRamp(for: .zero, startVolume: &v1, endVolume: &end, timeRange: &tr)
        let tracks = try await Composer.build(p, half, style, height: 360).asset.loadTracks(withMediaType: .audio)
        var filled = 0
        for tr in tracks where try await tr.load(.timeRange).duration.seconds > 1 { filled += 1 }
        let clips = (style.intro && !style.introPath.isEmpty) || (style.outro && !style.outroPath.isEmpty)
        check(filled == 3 + (clips ? 1 : 0), "cleaned voice, original voice, system sound\(clips ? " and intro/outro" : "") all make it into the edit (\(filled) tracks)")
        check(mixed.count == 2 && abs(v0 - 0.5) < 0.01 && abs(v1 - 0.5) < 0.01, "Studio Sound at 50% blends cleaned and original voice equally (\(v0), \(v1))")

        var s = style
        s.resolution = 1080
        s.exportFolder = dir.appendingPathComponent("export").path
        let t1 = Date()
        let url = try await Composer.export(p, edit, s) { _ in }
        print(String(format: "    exported in %.1f s", Date().timeIntervalSince(t1)))
        try await checkExport(url, p, edit, s)

        // Listen to the result: the fillers are gone and no real word was clipped.
        let intro = try Processor.probeDuration(URL(fileURLWithPath: s.introPath.isEmpty ? url.path : s.introPath))
        let kept = edit.keeps(s).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let wav = dir.appendingPathComponent("heard.wav").path
        try Tools.ffmpeg(["-ss", s.introPath.isEmpty ? "0" : "\(intro)", "-t", "\(kept)", "-i", url.path, "-ar", "16000", "-ac", "1", wav])
        let heard = try Tools.run(Tools.path("whisper-cli") ?? "whisper-cli", ["-m", Tools.whisperModel.path, "-f", wav, "-np", "-nt", "--prompt", "Umm, uh, so, um."]).out.lowercased()
        print("    heard: \(heard.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))")
        let heardWords = Set(heard.components(separatedBy: CharacterSet.letters.inverted))
        check(heardWords.isDisjoint(with: Style.fillers), "no fillers left in the export")
        check(["today", "show", "works", "first", "terminal", "then", "build"].allSatisfy(heardWords.contains), "every real word survived the cuts")
    }

    static func recordTest(_ dir: URL, seconds: Double) async throws {
        print("Recording \(Int(seconds)) s of the real screen")
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let mic = micOK ? AVCaptureDevice.default(for: .audio)?.uniqueID : nil
        print("    microphone: \(mic == nil ? "not allowed for this process, recording without" : AVCaptureDevice.default(for: .audio)!.localizedName)")
        let p = Project(folder: dir.appendingPathComponent("2026-01-01 11-00-00"))
        try FileManager.default.createDirectory(at: p.folder, withIntermediateDirectories: true)
        let r = Recorder()
        try await r.start(displayID: nil, micID: mic, systemAudio: true, folder: p.folder)
        if CommandLine.arguments.contains("--speak") {
            // Talk through the speakers so the real mic hears speech with a filler in it.
            try await Task.sleep(for: .seconds(1))
            Task.detached { try? Tools.run("/usr/bin/say", ["-v", "Samantha", "Testing the capture app. Um, this is the microphone check."]) }
            try await Task.sleep(for: .seconds(max(0, seconds - 1)))
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }
        let ev = try await r.stop()
        check(abs(ev.duration - seconds) < 1.0, String(format: "recorded %.2f s", ev.duration))
        let dur = try Processor.probeDuration(p.screen)
        check(abs(dur - ev.duration) < 0.3, String(format: "video file runs the whole time (%.2f s)", dur))
        check(ev.pixelWidth >= 1280, "captured at full resolution (\(Int(ev.pixelWidth))x\(Int(ev.pixelHeight)))")
        if mic != nil {
            check(FileManager.default.fileExists(atPath: p.mic.path), "microphone file written")
            check(abs((ev.micStart ?? 0) - ev.videoStart) < 1, String(format: "mic and video start together (%.3f s apart)", (ev.micStart ?? 0) - ev.videoStart))
        }
        let edit = try await Processor.process(p) { print("    \($0)") }
        var s = Style()
        s.resolution = 1080
        s.intro = false; s.outro = false
        s.exportFolder = dir.appendingPathComponent("export").path
        let url = try await Composer.export(p, edit, s) { _ in }
        try await checkExport(url, p, edit, s)
    }

    static func checkExport(_ url: URL, _ p: Project, _ edit: Edit, _ s: Style) async throws {
        check(FileManager.default.fileExists(atPath: url.path), "exported \(url.lastPathComponent)")
        let asset = AVURLAsset(url: url)
        let v = try await asset.loadTracks(withMediaType: .video).first
        let size = try await v?.load(.naturalSize) ?? .zero
        check(size == CGSize(width: 1920, height: 1080), "export is 1920x1080 (\(Int(size.width))x\(Int(size.height)))")
        check(try await !asset.loadTracks(withMediaType: .audio).isEmpty, "export has sound")

        var intro = 0.0, outro = 0.0
        if s.intro, !s.introPath.isEmpty { intro = try Processor.probeDuration(URL(fileURLWithPath: s.introPath)) }
        if s.outro, !s.outroPath.isEmpty { outro = try Processor.probeDuration(URL(fileURLWithPath: s.outroPath)) }
        let kept = edit.keeps(s).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let total = try await asset.load(.duration).seconds
        check(abs(total - (intro + kept + outro)) < 0.5, String(format: "length = intro %.1f + kept %.1f + outro %.1f (got %.1f)", intro, kept, outro, total))

        // Look at a frame from the recording part: corner is background, middle is the screen.
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(seconds: intro + min(1, kept / 2), preferredTimescale: 600))
        let frame = dirOf(url).appendingPathComponent("frame.png")
        if let dest = CGImageDestinationCreateWithURL(frame as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        let corner = pixel(cg, 6, 6), centre = pixel(cg, cg.width / 2, cg.height / 2)
        if let wall = NSImage(contentsOf: Composer.wallpaper(s.background))?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let w = pixel(wall, 6 * wall.width / cg.width, 6 * wall.height / cg.height)
            check(abs(corner.r - w.r) < 25 && abs(corner.g - w.g) < 25 && abs(corner.b - w.b) < 25,
                  "frame sits on the \(s.background) wallpaper (corner \(corner), wallpaper \(w))")
        } else { check(false, "wallpaper \(s.background) is installed") }
        check(centre != corner, "the screen is drawn in the middle")
        let srt = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)) ?? ""
        check(edit.words.isEmpty || srt.contains("-->"), "captions file written")
        print("    output: \(url.path)")
        print("    frame:  \(frame.path)")
    }

    static func dirOf(_ u: URL) -> URL { u.deletingLastPathComponent() }

    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    static func loudness(_ path: String) throws -> Double {
        let err = try Tools.ffmpeg(["-i", path, "-af", "ebur128", "-f", "null", "-"])
        guard let r = err.range(of: "I:", options: .backwards) else { return 0 }
        return Double(err[r.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
    }
}
