import Foundation
import AVFoundation

/// What the recorder logs beside the video. Times are seconds from the first video frame;
/// positions are 0...1 across the captured display, top-left origin.
struct EventsLog: Codable {
    var videoStart: Double = 0      // host-clock seconds of the first frame
    var micStart: Double?           // host-clock seconds of the first mic sample
    var micSegments: [MicSegment] = [] // after a mic switch mid-recording: each mic's own file, from its start
    var systemStart: Double?
    var pixelWidth: Double = 0
    var pixelHeight: Double = 0
    var duration: Double = 0
    var cursor: [[Double]] = []     // [t, u, v]
    var clicks: [[Double]] = []     // [t, u, v]
    var activity: [[Double]] = []   // [t, fraction of the screen that changed]
}

struct MicSegment: Codable {
    var file: String
    var start: Double               // host-clock seconds of its first sample
}

struct Word: Codable, Identifiable, Equatable {
    var id: Int
    var text: String
    var start: Double
    var end: Double
    var filler: Bool
    var override: Bool?             // nil = follow the cleanup rules

    var bare: String { text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
}

/// A pause between two words (or before the first / after the last).
struct Gap: Codable, Identifiable, Equatable {
    var id: Int
    var start: Double
    var end: Double
    var afterWord: Int              // -1 = head of the recording, words.count-1 after the last = tail
    var head: Bool
    var tail: Bool
    var screenBusy: Bool            // the screen changed, or the mouse clicked, during it
    var override: Bool?

    var length: Double { end - start }
}

/// The transcript plus what this recording's cleanup actions are set to. Nothing is cut until
/// you ask: Remove filler words, Shorten pauses, and Studio Sound are switches per recording.
struct Edit: Codable, Equatable {
    var duration: Double
    var words: [Word]
    var gaps: [Gap]
    var removeFillers = false
    var fillerKinds = ["um", "repeat"]   // which kinds Remove filler words takes out
    var shortenPauses = false
    var studioSound = true
    var studioAmount = 1.0               // 0 = the original mic, 1 = fully cleaned voice

    static let kinds: [(id: String, name: String)] = [
        ("um", "Um, uh, hmm"), ("repeat", "Repeated words"), ("tic", "Like, you know, I mean, basically"),
    ]
}

/// Cleanup rules, the look of the frame, intro/outro and export. One set, remembered between launches.
struct Style: Codable, Equatable {
    var background = "aurora"
    var imagePath = ""
    var padding = 0.06              // of the output width
    var radius = 0.012              // of the output width
    var shadow = true
    var autoZoom = true
    var zoomAmount = 1.6
    var clickRings = true
    var resolution = 1080

    var autoCleanup = false         // apply all three cleanup actions to each new recording
    var maxPause = 0.7              // pauses longer than this get cut down to keepPause
    var keepPause = 0.35
    var keepBusyPauses = true       // don't cut a pause while the screen is moving

    var intro = false               // off until you choose a clip in the inspector
    var introPath = ""
    var outro = false
    var outroPath = ""
    var exportFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Capture/Exports").path

    static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "ah", "ahh", "er", "erm", "hmm", "hm", "mm", "mhm", "eh"]

    static func load() -> Style {
        guard let d = UserDefaults.standard.data(forKey: "style"),
              let s = try? JSONDecoder().decode(Style.self, from: d) else { return Style() }
        return s
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "style")
    }
}

extension Style {
    // Decoding keeps working when a later version adds a field.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decode(T.self, forKey: k) { v = x } }
        get(.background, &background); get(.imagePath, &imagePath); get(.padding, &padding); get(.radius, &radius)
        get(.shadow, &shadow); get(.autoZoom, &autoZoom); get(.zoomAmount, &zoomAmount); get(.clickRings, &clickRings)
        get(.resolution, &resolution); get(.autoCleanup, &autoCleanup)
        get(.maxPause, &maxPause); get(.keepPause, &keepPause); get(.keepBusyPauses, &keepBusyPauses)
        get(.intro, &intro); get(.introPath, &introPath); get(.outro, &outro); get(.outroPath, &outroPath)
        get(.exportFolder, &exportFolder)
        // The flat gradients of the first version are gone: move them to the default wallpaper.
        if !["wallpaper", "image", "none"].contains(background), !Composer.wallpapers.contains(where: { $0.id == background }) {
            background = Style().background
        }
    }
}

extension Edit {
    // Decoding keeps working for edits saved before the cleanup switches existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decode(Double.self, forKey: .duration)
        words = try c.decode([Word].self, forKey: .words)
        gaps = try c.decode([Gap].self, forKey: .gaps)
        func get<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decode(T.self, forKey: k) { v = x } }
        get(.removeFillers, &removeFillers); get(.fillerKinds, &fillerKinds); get(.shortenPauses, &shortenPauses)
        get(.studioSound, &studioSound); get(.studioAmount, &studioAmount)
    }

    static let tics: Set<String> = ["like", "basically", "actually", "literally"]

    /// "um", "repeat" (the first of a doubled word: "the the"), "tic" (like, you know), or nil.
    func fillerKind(_ i: Int) -> String? {
        let b = words[i].bare
        if b.isEmpty { return nil }
        if Style.fillers.contains(b) { return "um" }
        let next = i + 1 < words.count ? words[i + 1] : nil, prev = i > 0 ? words[i - 1].bare : ""
        if let n = next, n.bare == b, n.start - words[i].end < 1 { return "repeat" }
        if Edit.tics.contains(b) { return "tic" }
        if (b == "you" && next?.bare == "know") || (b == "i" && next?.bare == "mean") { return "tic" }
        if (prev == "you" && b == "know") || (prev == "i" && b == "mean") { return "tic" }
        return nil
    }

    func fillers(_ kind: String) -> [Int] { words.indices.filter { fillerKind($0) == kind } }

    /// Pauses that Shorten pauses would trim (it never touches the head and tail, which are always trimmed).
    func longPauses(_ s: Style) -> [Gap] {
        gaps.filter { !$0.head && !$0.tail && $0.length > s.maxPause && !(s.keepBusyPauses && $0.screenBusy) }
    }

    func isCut(_ w: Word, _ s: Style) -> Bool {
        w.override ?? (removeFillers && fillerKind(w.id).map { fillerKinds.contains($0) } == true)
    }

    func isCut(_ g: Gap, _ s: Style) -> Bool {
        if let o = g.override { return o }
        if words.isEmpty { return false }   // a silent screen-only take: keep it all
        guard g.head || g.tail ? g.length > 0.6 : shortenPauses && g.length > s.maxPause else { return false }
        return !(s.keepBusyPauses && g.screenBusy)
    }

    /// The source time ranges to remove. With the voice's loudness (`energy`), cut words are trimmed
    /// to where their sound really starts and ends: whisper's word times run up to ~0.1 s late, which
    /// left the start of an "uh" in and clipped the word after it.
    func cuts(_ s: Style, _ energy: Energy? = nil) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        // Consecutive cut words go as one run.
        var i = 0
        while i < words.count {
            guard isCut(words[i], s) else { i += 1; continue }
            var j = i
            while j + 1 < words.count, isCut(words[j + 1], s) { j += 1 }
            let a = words[i].start, b = words[j].end
            if let energy {
                let prev = i > 0 ? words[i - 1].end : 0, next = j + 1 < words.count ? words[j + 1].start : duration
                out.append(energy.cleanCut(a, b, after: prev, before: next))
            } else {
                out.append(a...b)
            }
            i = j + 1
        }
        for g in gaps where isCut(g, s) {
            let r: ClosedRange<Double>
            if g.head { r = 0...max(0, g.end - 0.2) }
            else if g.tail { r = min(duration, g.start + 0.5)...duration }
            else {
                let keep = min(s.keepPause, g.length) / 2
                r = (g.start + keep)...(g.end - keep)
            }
            if r.upperBound - r.lowerBound > 0.02 { out.append(r) }
        }
        return out
    }

    /// The source time ranges to keep, in order. Never empty.
    func keeps(_ s: Style, _ energy: Energy? = nil) -> [ClosedRange<Double>] {
        let cuts = self.cuts(s, energy).sorted { $0.lowerBound < $1.lowerBound }
        var keeps: [ClosedRange<Double>] = []
        var t = 0.0
        for c in cuts {
            if c.lowerBound > t { keeps.append(t...c.lowerBound) }
            t = max(t, c.upperBound)
        }
        if t < duration { keeps.append(t...duration) }
        keeps = keeps.filter { $0.upperBound - $0.lowerBound >= 0.08 }
        return keeps.isEmpty ? [0...duration] : keeps
    }
}

/// One recording on disk: ~/Movies/Capture/<date time>/
final class Project: ObservableObject, Identifiable, Hashable {
    static let root = ProcessInfo.processInfo.environment["CAPTURE_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Capture")

    let folder: URL
    @Published var edit: Edit?
    @Published var status = ""
    @Published var processing = false

    var id: URL { folder }
    var name: String { folder.lastPathComponent }

    /// The name you gave it (title.txt in its folder). The folder itself never moves, so a
    /// recording can be renamed while it is still being written.
    @Published private(set) var customTitle: String?
    var titleURL: URL { folder.appendingPathComponent("title.txt") }

    func rename(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try? FileManager.default.removeItem(at: titleURL) } else { try? t.write(to: titleURL, atomically: true, encoding: .utf8) }
        customTitle = t.isEmpty ? nil : t
    }

    /// The export's file name: the title, minus characters Finder dislikes.
    var fileName: String {
        guard let t = customTitle else { return name }
        let safe = t.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return safe.isEmpty ? name : safe
    }

    /// Your name for it, else "Oct 25, 9:30 AM" from the folder's "2026-10-25 09-30-00"; any other folder name as it is.
    var title: String {
        if let customTitle { return customTitle }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        guard let d = f.date(from: name) else { return name }
        let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
        return d.formatted(.dateTime.month(.abbreviated).day().year(sameYear ? .omitted : .defaultDigits).hour().minute())
    }
    var screen: URL { folder.appendingPathComponent("screen.mov") }
    var mic: URL { folder.appendingPathComponent("mic.caf") }
    var system: URL { folder.appendingPathComponent("system.caf") }
    var eventsURL: URL { folder.appendingPathComponent("events.json") }
    var editURL: URL { folder.appendingPathComponent("edit.json") }
    var work: URL { folder.appendingPathComponent("work") }
    var voice: URL { work.appendingPathComponent("voice.wav") }      // cleaned (Studio Sound)
    var original: URL { work.appendingPathComponent("original.wav") } // the mic as it was, only leveled

    init(folder: URL) {
        self.folder = folder
        if let d = try? Data(contentsOf: editURL) { edit = try? JSONDecoder().decode(Edit.self, from: d) }
        let saved = (try? String(contentsOf: titleURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        customTitle = saved.isEmpty ? nil : saved
    }

    static func == (a: Project, b: Project) -> Bool { a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(folder) }

    func events() -> EventsLog {
        (try? JSONDecoder().decode(EventsLog.self, from: Data(contentsOf: eventsURL))) ?? EventsLog()
    }

    private var energyCache: Energy?
    /// The cleaned voice's loudness, for clean cuts. Loaded once.
    func energy() -> Energy? {
        let small = work.appendingPathComponent("voice16.wav")   // same voice at 16 kHz: quicker to read
        if energyCache == nil { energyCache = Energy(FileManager.default.fileExists(atPath: small.path) ? small : voice) }
        return energyCache
    }

    func save() {
        guard let edit else { return }
        try? JSONEncoder().encode(edit).write(to: editURL, options: .atomic)
    }

    static func newFolder() throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let url = root.appendingPathComponent(f.string(from: Date()))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func all() -> [Project] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("screen.mov").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(Project.init)
    }
}

/// The voice's loudness in 10 ms frames, to put cuts where the sound really starts and stops.
struct Energy {
    static let step = 0.01
    let db: [Float]
    let silence: Float              // below this a frame counts as silence

    init(db: [Float]) {
        self.db = db
        // The quiet floor of this recording, plus a margin; never above -40 dB.
        let sorted = db.sorted()
        let floor = sorted.isEmpty ? -80 : sorted[sorted.count / 10]
        silence = min(-40, floor + 20)
    }

    init?(_ url: URL) {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536) else { return nil }
        let per = Int(f.processingFormat.sampleRate * Energy.step)
        var out: [Float] = [], sum: Float = 0, n = 0
        while (try? f.read(into: buf)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(buf.frameLength) {
                sum += ch[i] * ch[i]; n += 1
                if n == per { out.append(20 * log10(max(sqrt(sum / Float(n)), 1e-7))); sum = 0; n = 0 }
            }
        }
        self.init(db: out)
    }

    func frame(_ t: Double) -> Int { max(0, min(db.count - 1, Int((t / Energy.step).rounded()))) }
    func time(_ i: Int) -> Double { Double(i) * Energy.step }
    func silent(_ i: Int) -> Bool { db[i] < silence }

    /// The quietest stretch in a window, the place a cut is least heard: its first frame, or with
    /// `latest` its last (an end cut goes as late as it can, right up to the next word's onset).
    func valley(_ a: Double, _ b: Double, latest: Bool = false) -> Double {
        let i0 = frame(a), i1 = max(i0, frame(b))
        let low = (i0...i1).map { db[$0] }.min() ?? 0
        let quiet = (i0...i1).filter { db[$0] <= low + 3 }
        return time((latest ? quiet.last : quiet.first) ?? i0)
    }

    /// A cut for words whisper placed at a...b, between the kept word ending at `prev` and the one
    /// starting at `next`: from the true start of the sound to its true end, taking the silence
    /// around it too but leaving a natural pause of up to 0.25 s.
    func cleanCut(_ a: Double, _ b: Double, after prev: Double, before next: Double) -> ClosedRange<Double> {
        guard !db.isEmpty, b > a else { return a...b }
        // Start: the onset after a silence just before, else the quietest point near whisper's start.
        var s = a
        let back = frame(max(prev, a - 0.25))
        if let k = (back...frame(a)).last(where: silent) { s = time(k + 1) } else { s = valley(max(prev, a - 0.12), a + 0.04) }
        // End: the first silence just after, else the quietest point near whisper's end (never into the start).
        var e = b
        let fwd = frame(min(next, b + 0.25))
        if let k = (frame(b)...max(frame(b), fwd)).first(where: silent) { e = time(k) }
        else { e = valley(max(s + 0.08, b - 0.15), min(next + 0.05, b + 0.05), latest: true) + Energy.step }
        if e <= s { return a...b }
        // The silence on each side, and how much of it to keep.
        var i = frame(s) - 1
        while i > frame(prev), silent(i) { i -= 1 }
        let pre = max(0, s - time(i + 1))
        var j = frame(e)
        while j < frame(next), silent(j) { j += 1 }
        let post = max(0, time(j) - e)
        let keep = min(0.25, pre + post)
        var after = min(post, keep / 2)
        let before = min(pre, keep - after)
        after = min(post, keep - before)
        return (s - (pre - before))...(e + (post - after))
    }
}
