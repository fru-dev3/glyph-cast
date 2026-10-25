import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") || args.contains("--record-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task {
        let ok = await SelfTest.run(args)
        exit(ok ? 0 : 1)
    }
    app.run()
} else if let i = args.firstIndex(of: "--process"), i + 1 < args.count {
    // Headless: process and export one recording folder with the saved settings.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task {
        do {
            let p = Project(folder: URL(fileURLWithPath: args[i + 1]))
            var t = Date()
            var edit = args.contains("--export-only") && p.edit != nil ? p.edit! : try await Processor.process(p) { print($0) }
            print(String(format: "processed in %.1f s: %d words, %d fillers", Date().timeIntervalSince(t), edit.words.count, edit.words.filter(\.filler).count))
            if args.contains("--clean") {   // as if Clean up everything was clicked
                edit.removeFillers = true; edit.shortenPauses = true; edit.studioSound = true
                for c in edit.cuts(Style.load(), p.energy()).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    print(String(format: "cut %.2f-%.2f", c.lowerBound, c.upperBound))
                }
            }
            var style = Style.load()
            if let r = args.firstIndex(of: "--height"), r + 1 < args.count { style.resolution = Int(args[r + 1]) ?? style.resolution }
            if let o = args.firstIndex(of: "--out"), o + 1 < args.count { style.exportFolder = args[o + 1] }
            t = Date()
            let url = try await Composer.export(p, edit, style) { _ in }
            print(String(format: "exported in %.1f s: %@", Date().timeIntervalSince(t), url.path))
            exit(0)
        } catch {
            print("failed: \(error.localizedDescription) [\(error)]")
            exit(1)
        }
    }
    app.run()
} else {
    CaptureApp.main()
}
