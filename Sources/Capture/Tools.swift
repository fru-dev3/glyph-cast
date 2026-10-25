import Foundation

/// External tools (ffmpeg, whisper-cli, deep-filter) and the models they need.
enum Tools {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Capture")
    static let models = support.appendingPathComponent("models")

    static var whisperModel: URL { models.appendingPathComponent("ggml-base.en.bin") }
    static var vadModel: URL { models.appendingPathComponent("ggml-silero-vad.bin") }
    static var rnnModel: URL { models.appendingPathComponent("voice.rnnn") }
    static var deepFilter: URL { models.appendingPathComponent("deep-filter") }

    /// What the first run downloads, so a fresh Mac needs nothing but Homebrew's ffmpeg and whisper-cpp.
    static let downloads: [(URL, String)] = [
        (whisperModel, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"),
        (vadModel, "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"),
        (rnnModel, "https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn"),
        (deepFilter, "https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-aarch64-apple-darwin"),
    ]

    static func path(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var ffmpeg: String { path("ffmpeg") ?? "ffmpeg" }

    /// Missing pieces, in words, for the home screen. Empty when ready.
    static func missing() -> [String] {
        var out: [String] = []
        if path("ffmpeg") == nil { out.append("ffmpeg (brew install ffmpeg)") }
        if path("whisper-cli") == nil { out.append("whisper-cli (brew install whisper-cpp)") }
        return out
    }

    static func ensureModels(log: @escaping (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        for (dest, url) in downloads where !FileManager.default.fileExists(atPath: dest.path) {
            log("Downloading \(dest.lastPathComponent)")
            let (tmp, resp) = try await URLSession.shared.download(from: URL(string: url)!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Fail("Download failed: \(url)") }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            if dest == deepFilter { chmod(dest.path, 0o755) }
        }
    }

    /// Runs a tool to completion. Output goes through temp files so a chatty
    /// tool can never fill a pipe and hang.
    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> (out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let tmp = FileManager.default.temporaryDirectory
        let o = tmp.appendingPathComponent(UUID().uuidString), e = tmp.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: o.path, contents: nil)
        FileManager.default.createFile(atPath: e.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: o); try? FileManager.default.removeItem(at: e) }
        p.standardOutput = try FileHandle(forWritingTo: o)
        p.standardError = try FileHandle(forWritingTo: e)
        try p.run()
        p.waitUntilExit()
        let out = (try? String(contentsOf: o, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: e, encoding: .utf8)) ?? ""
        if p.terminationStatus != 0 {
            throw Fail("\((exe as NSString).lastPathComponent) failed (\(p.terminationStatus)): \(err.suffix(600))")
        }
        return (out, err)
    }

    @discardableResult
    static func ffmpeg(_ args: [String]) throws -> String {
        try run(ffmpeg, ["-hide_banner", "-nostdin", "-y"] + args).err
    }
}

struct Fail: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
