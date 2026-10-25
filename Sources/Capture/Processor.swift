import Foundation

/// After a recording: clean the voice, transcribe it, and find fillers and dead air.
/// Writes work/voice.wav (the audio every export uses) and edit.json.
enum Processor {
    static func process(_ p: Project, log: @escaping (String) -> Void) async throws -> Edit {
        try FileManager.default.createDirectory(at: p.work, withIntermediateDirectories: true)
        try await Tools.ensureModels(log: log)
        let ev = p.events()
        let duration = ev.duration > 0 ? ev.duration : try probeDuration(p.screen)
        let w = p.work.path

        // 1. Line the mic up with the first video frame, as 48 kHz mono.
        log("Lining up the microphone")
        let raw = "\(w)/mic48.wav"
        if ev.micSegments.count > 1 {
            // The mic was switched mid-recording: put each mic's file at its own start, then mix.
            var args: [String] = [], chains: [String] = []
            for (i, seg) in ev.micSegments.enumerated() {
                args += ["-i", p.folder.appendingPathComponent(seg.file).path]
                let off = seg.start - ev.videoStart
                let shift = off >= 0 ? "adelay=\(Int(off * 1000)):all=1" : "atrim=start=\(-off),asetpts=PTS-STARTPTS"
                chains.append("[\(i):a]aformat=channel_layouts=mono,\(shift)[m\(i)]")
            }
            let mix = chains.joined(separator: ";") + ";" + ev.micSegments.indices.map { "[m\($0)]" }.joined()
                + "amix=inputs=\(ev.micSegments.count):normalize=0,apad[out]"
            try Tools.ffmpeg(args + ["-filter_complex", mix, "-map", "[out]", "-t", "\(duration)", "-ar", "48000", "-c:a", "pcm_f32le", raw])
        } else if FileManager.default.fileExists(atPath: p.mic.path) {
            let offset = (ev.micStart ?? ev.videoStart) - ev.videoStart
            let shift = offset >= 0 ? "adelay=\(Int(offset * 1000)):all=1" : "atrim=start=\(-offset),asetpts=PTS-STARTPTS"
            try Tools.ffmpeg(["-i", p.mic.path, "-af", "\(shift),apad", "-t", "\(duration)", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", raw])
        } else {
            try Tools.ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "\(duration)", "-c:a", "pcm_f32le", raw])
        }

        // 2. Remove background noise: DeepFilterNet if it runs here, RNNoise in ffmpeg if not.
        log("Removing background noise")
        var clean = "\(w)/df/mic48.wav"
        try? FileManager.default.removeItem(atPath: "\(w)/df")
        do {
            try Tools.run(Tools.deepFilter.path, ["-D", "--pf", "-a", "40", "-o", "\(w)/df", raw])
        } catch {
            clean = "\(w)/rnn.wav"
            try Tools.ffmpeg(["-i", raw, "-af", "arnndn=m='\(Tools.rnnModel.path)':mix=0.9", "-c:a", "pcm_f32le", clean])
        }

        // 3. Studio voice: trim rumble, tame sibilance, even out, then loudness to YouTube's -14 LUFS (two passes).
        log("Leveling the voice")
        let chain = "highpass=f=75,lowpass=f=16000,equalizer=f=180:t=q:w=1.2:g=-1.5,equalizer=f=3500:t=q:w=1.5:g=2,deesser=i=0.4,acompressor=threshold=-22dB:ratio=3:attack=8:release=160:makeup=2"
        try level(clean, chain, to: p.voice.path)
        try makeOriginal(p)

        // 4. Words with timings. Silero VAD keeps whisper's timestamps near the speech.
        log("Transcribing")
        let v16 = "\(w)/voice16.wav"
        try Tools.ffmpeg(["-i", p.voice.path, "-ar", "16000", "-ac", "1", v16])
        let prompt = "Umm, so, uh, let me think. Hmm, okay, um, here's what I, uh, wanted to show you."
        try Tools.run(Tools.path("whisper-cli") ?? "whisper-cli", [
            "-m", Tools.whisperModel.path, "-f", v16, "-ml", "1", "-sow", "-oj", "-of", "\(w)/transcript",
            "--vad", "-vm", Tools.vadModel.path, "--prompt", prompt, "-np", "-t", "8",
        ])
        let words = try readWhisper(URL(fileURLWithPath: "\(w)/transcript.json"))

        // 5. Exact silences, to tighten the word edges whisper smears over pauses.
        log("Finding pauses and fillers")
        let silences = try detectSilence(p.voice.path)
        var edit = build(words: words, silences: silences, events: ev, duration: duration)
        if Style.load().autoCleanup { edit.removeFillers = true; edit.shortenPauses = true }
        try JSONEncoder().encode(edit).write(to: p.editURL, options: .atomic)
        log("Ready")
        return edit
    }

    /// Two-pass loudness to YouTube's -14 LUFS after `chain`.
    static func level(_ input: String, _ chain: String, to output: String) throws {
        let measured = try Tools.ffmpeg(["-i", input, "-af", "\(chain),loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"])
        let m = loudnormStats(measured)
        // No speech at all (a silent take): leave the level alone rather than amplify the room.
        let speech = (Double(m["input_i"] ?? "") ?? -99) > -60
        let norm = !speech ? "anull" : "loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=\(m["input_i"] ?? "-24"):measured_TP=\(m["input_tp"] ?? "-3"):measured_LRA=\(m["input_lra"] ?? "7"):measured_thresh=\(m["input_thresh"] ?? "-34"):offset=\(m["target_offset"] ?? "0"):linear=true"
        try Tools.ffmpeg(["-i", input, "-af", "\(chain),\(norm)", "-ar", "48000", "-ac", "1", "-c:a", "pcm_s24le", output])
    }

    /// The mic without Studio Sound, at the same loudness, so the Studio Sound slider can blend the two.
    static func makeOriginal(_ p: Project) throws {
        let raw = p.work.appendingPathComponent("mic48.wav").path
        guard FileManager.default.fileExists(atPath: raw) else { return }
        try level(raw, "highpass=f=60", to: p.original.path)
    }

    static func probeDuration(_ url: URL) throws -> Double {
        let out = try Tools.run(Tools.path("ffprobe") ?? "ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]).out
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func loudnormStats(_ stderr: String) -> [String: String] {
        guard let a = stderr.lastIndex(of: "{"), let b = stderr.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(stderr[a...b].utf8)) as? [String: String] else { return [:] }
        return obj
    }

    static func readWhisper(_ url: URL) throws -> [(String, Double, Double)] {
        struct W: Decodable {
            struct Seg: Decodable { struct Off: Decodable { let from: Int; let to: Int }; let offsets: Off; let text: String }
            let transcription: [Seg]
        }
        let w = try JSONDecoder().decode(W.self, from: Data(contentsOf: url))
        return w.transcription.compactMap { s in
            let t = s.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("[") || t.hasPrefix("(") { return nil }
            return (t, Double(s.offsets.from) / 1000, Double(s.offsets.to) / 1000)
        }
    }

    static func detectSilence(_ path: String) throws -> [ClosedRange<Double>] {
        let err = try Tools.ffmpeg(["-i", path, "-af", "silencedetect=n=-42dB:d=0.18", "-f", "null", "-"])
        let num = { (key: String) -> [Double] in
            err.components(separatedBy: "\n").compactMap { line -> Double? in
                guard let r = line.range(of: "\(key): ") else { return nil }
                return Double(line[r.upperBound...].split(separator: " ").first ?? "")
            }
        }
        let starts = num("silence_start"), ends = num("silence_end")
        return zip(starts, ends + Array(repeating: .infinity, count: max(0, starts.count - ends.count))).map { $0...$1 }
    }

    /// Pure logic, tested by the self-test: words + silences + screen events -> an Edit.
    static func build(words raw: [(String, Double, Double)], silences: [ClosedRange<Double>], events: EventsLog, duration: Double) -> Edit {
        // Trim each word to the speech it overlaps: whisper stretches a word across the pause after it.
        var words: [Word] = []
        for (text, s0, e0) in raw {
            let span = s0...max(s0, e0)
            var pieces = [span]
            for sil in silences where sil.overlaps(span) {
                pieces = pieces.flatMap { subtract($0, sil) }
            }
            // A word entirely inside a "silence" was spoken quietly: keep whisper's timing.
            let best = pieces.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) ?? span
            var s = best.lowerBound, e = best.upperBound
            if let prev = words.last, s < prev.end { s = prev.end }
            e = min(max(e, s + 0.05), duration)
            if e - s < 0.04 { continue }
            var w = Word(id: words.count, text: text, start: s, end: e, filler: false)
            w.filler = Style.fillers.contains(w.bare)
            words.append(w)
        }

        // Every pause between words (and before the first, after the last).
        var gaps: [Gap] = []
        var prevEnd = 0.0
        for i in 0...words.count {
            let start = prevEnd, end = i < words.count ? words[i].start : duration
            if end - start > 0.3 {
                gaps.append(Gap(id: gaps.count, start: start, end: end, afterWord: i - 1, head: i == 0, tail: i == words.count,
                                screenBusy: busy(events, start, end)))
            }
            if i < words.count { prevEnd = words[i].end }
        }
        return Edit(duration: duration, words: words, gaps: gaps)
    }

    static func subtract(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard a.overlaps(b) else { return [a] }
        var out: [ClosedRange<Double>] = []
        if b.lowerBound > a.lowerBound { out.append(a.lowerBound...b.lowerBound) }
        if b.upperBound < a.upperBound { out.append(b.upperBound...a.upperBound) }
        return out
    }

    /// Did something happen on screen: a click, real screen change, or the mouse travelling?
    static func busy(_ ev: EventsLog, _ a: Double, _ b: Double) -> Bool {
        if ev.clicks.contains(where: { $0[0] >= a && $0[0] <= b }) { return true }
        let changed = ev.activity.filter { $0[0] >= a && $0[0] <= b }.reduce(0.0) { $0 + $1[1] }
        if changed > 0.02 { return true }
        let pts = ev.cursor.filter { $0[0] >= a && $0[0] <= b }
        let travel = zip(pts, pts.dropFirst()).reduce(0.0) { $0 + hypot($1.1[1] - $1.0[1], $1.1[2] - $1.0[2]) }
        return travel > 0.15
    }
}
