import AppKit
import ScreenCaptureKit
import AVFoundation
import AVKit

/// `Capture --uitest <out dir>`: drives the real window the way a person would. It finds controls
/// through the app's own accessibility tree and clicks them with real mouse events sent to the
/// window, so it needs no Accessibility permission. Screenshots of each step land in <out dir>.
@MainActor
enum UITest {
    static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    static var failures = 0
    static var step = 0
    static var modifiers: NSEvent.ModifierFlags?

    struct Element { let role: String; let label: String; let id: String; let frame: CGRect; let obj: NSObject }

    static func start() {
        guard let i = CommandLine.arguments.firstIndex(of: "--uitest") else { return }
        if i + 1 < CommandLine.arguments.count { out = URL(fileURLWithPath: CommandLine.arguments[i + 1]) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(2))
            await run()
            print(failures == 0 ? "UI ALL PASSED" : "UI \(failures) FAILED")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
        fflush(stdout)
        if !ok { failures += 1 }
    }

    static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 800 } }

    static func elements() -> [Element] {
        var out: [Element] = []
        func walk(_ o: Any, depth: Int) {
            if CommandLine.arguments.contains("--types") { print(String(repeating: " ", count: depth) + "\(type(of: o))") }
            guard depth < 60, let e = o as? NSObject else { return }
            // SwiftUI's nodes speak the informal (Objective-C) accessibility API, so ask by name.
            func get(_ key: String) -> Any? { e.responds(to: Selector((key))) ? e.value(forKey: key) : nil }
            let frame = (get("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            out.append(Element(role: get("accessibilityRole") as? String ?? "",
                               label: [get("accessibilityLabel"), get("accessibilityTitle"), get("accessibilityValue")].compactMap { $0 as? String }.first { !$0.isEmpty } ?? "",
                               id: get("accessibilityIdentifier") as? String ?? "", frame: frame, obj: e))
            for c in get("accessibilityChildren") as? [Any] ?? [] { walk(c, depth: depth + 1) }
        }
        // The main window first, then any popover or panel that is open.
        if let w = window { walk(w, depth: 0) }
        for w in NSApp.windows where w.isVisible && w !== window && w.className.contains("Popover") { walk(w.contentView as Any, depth: 0) }
        if let pill = AppModel.shared.hud.pill, pill.isVisible { walk(pill.contentView as Any, depth: 0) }
        return out
    }

    static func find(_ text: String, role: String? = nil) -> Element? {
        elements().first { ($0.label == text || $0.id == text) && (role == nil || $0.role == role) && $0.frame.width > 0 }
    }

    static func probe() {
        guard let w = window, let v = w.contentView else { return }
        for sel in ["_setAccessibilityEnabled:", "setAccessibilityEnhancedUserInterface:"] where NSApp.responds(to: Selector((sel))) {
            print("    app responds to \(sel)")
        }
        let f = w.frame
        for (x, y) in [(0.3, 0.5), (0.85, 0.8), (0.1, 0.9)] {
            let pt = CGPoint(x: f.minX + f.width * x, y: f.minY + f.height * y)
            let hit = v.accessibilityHitTest(pt)
            let a = hit as? NSAccessibilityProtocol
            print("    hit \(x),\(y): \(type(of: hit as Any)) role=\(a?.accessibilityRole()?.rawValue ?? "-") label=\(a?.accessibilityLabel() ?? "-") children=\(a?.accessibilityChildren()?.count ?? -1)")
        }
        print("    hosting children after hit: \((v as NSAccessibilityProtocol).accessibilityChildren()?.count ?? -1)")
    }

    static func dump() {

        for e in elements() where !e.label.isEmpty || !e.id.isEmpty {
            print("    \(e.role) '\(e.label)' id=\(e.id) \(e.frame.integral)")
        }
    }

    /// The switch of a Toggle sits on the same row as its label text.
    static func toggle(_ label: String) async -> Bool {
        guard var l = find(label) else { check(false, "found toggle '\(label)'"); return false }
        l = await visible(l, label)
        guard let sw = elements().first(where: { $0.role == "AXCheckBox" && abs($0.frame.midY - l.frame.midY) < 12 }) else {
            check(false, "found the switch for '\(label)'"); return false
        }
        return await press(sw)
    }

    /// Scrolls an element into the window if it is outside it.
    static func visible(_ e: Element, _ text: String) async -> Element {
        guard let w = window, !w.frame.insetBy(dx: 0, dy: 20).contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) else { return e }
        if e.obj.responds(to: Selector(("accessibilityScrollToVisible"))) { e.obj.perform(Selector(("accessibilityScrollToVisible"))) }
        try? await Task.sleep(for: .milliseconds(400))
        return find(text) ?? e
    }

    /// A real click: mouse down and up at the element's centre, delivered to the window.
    static func click(_ text: String, role: String? = nil, modifiers: NSEvent.ModifierFlags = []) async -> Bool {
        guard let e0 = find(text, role: role) else { check(false, "found '\(text)'"); return false }
        return await press(await visible(e0, text), modifiers: modifiers)
    }

    /// Presses the control the way VoiceOver does: runs its real action. Mouse events can't be used,
    /// since macOS won't bring a test-launched app to the front while someone is working.
    /// Option and Shift ride along through `UITest.modifiers`, which the transcript reads.
    static func press(_ e: Element, modifiers: NSEvent.ModifierFlags = []) async -> Bool {
        UITest.modifiers = modifiers
        defer { UITest.modifiers = nil }
        guard e.obj.responds(to: #selector(NSAccessibilityProtocol.accessibilityPerformPress)) else { check(false, "'\(e.label)' can be pressed"); return false }
        e.obj.perform(#selector(NSAccessibilityProtocol.accessibilityPerformPress))
        try? await Task.sleep(for: .milliseconds(400))
        return true
    }

    /// The player's area, in window points from the top-left (screenshot space at 1x).
    /// The frame the preview is showing, rendered from the player's own composition (no screen grab,
    /// so it works with the window on another Space).
    static func previewFrame() async -> CGImage? {
        guard let item = EditorRegistry.current?.player.currentItem else { return nil }
        let g = AVAssetImageGenerator(asset: item.asset)
        g.videoComposition = item.videoComposition
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        return try? await g.image(at: item.currentTime()).image
    }

    static func previewRect() -> CGRect {
        guard let w = window, let v = w.contentView, let pv = findView(AVPlayerView.self, in: v) else { return .zero }
        let r = pv.convert(pv.bounds, to: nil)
        return CGRect(x: r.minX, y: v.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    static func findView<T: NSView>(_ t: T.Type, in v: NSView) -> T? {
        if let x = v as? T { return x }
        for s in v.subviews { if let x = findView(t, in: s) { return x } }
        return nil
    }

    @discardableResult
    static func shot(_ name: String) async -> CGImage? {
        step += 1
        guard let w = window else { return nil }
        do {
            // Off-screen too: the test window may sit on another Space while someone uses the Mac.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { print("    screenshot: window not found"); return nil }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(scw.frame.width * 2); cfg.height = Int(scw.frame.height * 2)
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg)
            let url = out.appendingPathComponent(String(format: "%02d-%@.png", step, name))
            if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
            }
            print("    screenshot \(url.lastPathComponent)")
            return img
        } catch { print("    screenshot failed: \(error.localizedDescription); drawing the window offscreen instead") }
        // The window drawn by AppKit itself: no video in the player, but every control.
        guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let url = out.appendingPathComponent(String(format: "%02d-%@-drawn.png", step, name))
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return nil
    }

    static func wait(_ what: String, timeout: Double = 30, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        check(false, "\(what) (timed out)")
        return false
    }

    static func run() async {
        let model = AppModel.shared
        if window == nil {  // say why no window was found, instead of failing every step after
            print("    no main window: hidden=\(NSApp.isHidden) active=\(NSApp.isActive)")
            for w in NSApp.windows { print("    window \(w.className) visible=\(w.isVisible) frame=\(w.frame) title=\(w.title)") }
        }
        window?.setFrame(CGRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
        // SwiftUI builds its accessibility tree only for an assistive client; tell it one is here.
        NSApp.perform(Selector(("setAccessibilityEnhancedUserInterface:")), with: NSNumber(value: true))
        try? await Task.sleep(for: .seconds(1))
        if CommandLine.arguments.contains("--dump") { dump(); return }
        if !CommandLine.arguments.contains("--probe") {}
        if CommandLine.arguments.contains("--shot") { await shot("launch"); return }
        if CommandLine.arguments.contains("--preview-check") {
            _ = await wait("preview is ready to play") { EditorRegistry.current?.player.currentItem?.status == .readyToPlay }
            let item = EditorRegistry.current?.player.currentItem
            print("    status=\(item?.status.rawValue ?? -1) error=\(String(describing: item?.error)) building=\(EditorRegistry.current?.building ?? false) stateError=\(EditorRegistry.current?.error ?? "")")
            print("    duration=\(item?.duration.seconds ?? -1) time=\(EditorRegistry.current?.player.currentTime().seconds ?? -1)")
            try? await Task.sleep(for: .seconds(2))
            if let img = await shot("preview") {
                let pv = previewRect()
                let px = SelfTest.pixel(img, Int((pv.minX + pv.width * 0.03) * 2), Int((pv.minY + pv.height * 0.05) * 2))
                check(px.r + px.g + px.b > 60, "preview shows the wallpaper backdrop (pixel \(px))")
            }
            return
        }
        guard let p = model.selected, let edit = p.edit else { check(false, "a processed project is open"); return }
        check(true, "editor opened on \(p.name)")
        _ = await wait("preview built") { find("Transcript") != nil }
        _ = await wait("preview is ready to play") { EditorRegistry.current?.player.currentItem?.status == .readyToPlay }
        if let e = EditorRegistry.current?.player.currentItem?.error { check(false, "preview error: \(e)") }
        await EditorRegistry.current?.player.seek(to: CMTime(seconds: 9, preferredTimescale: 600))
        try? await Task.sleep(for: .seconds(2))
        await shot("editor")

        // Start from the defaults; the user's own settings come back at the end.
        let style0 = model.style
        model.style = Style()
        try? await Task.sleep(for: .seconds(1))

        // A recording opens with nothing cut: the cleanup is one click each, as in Descript.
        var e0 = edit
        e0.removeFillers = false; e0.shortenPauses = false; e0.studioSound = true; e0.studioAmount = 1
        for i in e0.words.indices { e0.words[i].override = nil }
        for i in e0.gaps.indices { e0.gaps[i].override = nil }
        p.edit = e0
        try? await Task.sleep(for: .seconds(1))
        let filler = edit.words.first { edit.fillerKind($0.id) == "um" }!
        check(!p.edit!.isCut(p.edit!.words[filler.id], model.style), "fillers are highlighted, not cut, until you ask")
        check(find("Waveform") != nil, "the waveform timeline is under the player")
        _ = await wait("the waveform has loaded", timeout: 15) { !(EditorRegistry.current?.peaks.isEmpty ?? true) }

        if await click("action-fillers") {
            check(p.edit?.removeFillers == true && p.edit!.isCut(p.edit!.words[filler.id], model.style), "Remove filler words cuts '\(filler.text)'")
            try? await Task.sleep(for: .seconds(2))
            await shot("fillers-removed")
        }
        _ = await click("Remove filler words options")
        try? await Task.sleep(for: .seconds(1))
        let labels = elements().map(\.label)
        let listed = Edit.kinds.allSatisfy { k in labels.contains { $0.hasPrefix(k.name) } }
        check(listed, "the filler options list each kind")
        await shot("filler-options")
        _ = await click("Remove filler words options")
        try? await Task.sleep(for: .milliseconds(500))
        _ = await click("action-fillers")
        check(p.edit?.removeFillers == false && !p.edit!.isCut(p.edit!.words[filler.id], model.style), "clicking again puts the fillers back")

        if await click("cleanup-all") {
            let e = p.edit!
            check(e.removeFillers && e.shortenPauses && e.studioSound, "Clean up everything turns on all three")
            check(e.longPauses(model.style).allSatisfy { e.isCut($0, model.style) }, "every long pause is cut (\(e.longPauses(model.style).count))")
            try? await Task.sleep(for: .seconds(2.5))
            await shot("cleaned-up")
        }
        if await click("action-studio") {
            check(p.edit?.studioSound == false, "Studio Sound switches off")
            _ = await wait("preview rebuilt", timeout: 20) { EditorRegistry.current?.building == false }
            try? await Task.sleep(for: .seconds(1))
            if let params = EditorRegistry.current?.player.currentItem?.audioMix?.inputParameters, params.count == 2 {
                var v: Float = -1, end: Float = 0, tr = CMTimeRange()
                _ = params[0].getVolumeRamp(for: .zero, startVolume: &v, endVolume: &end, timeRange: &tr)
                check(v == 0, "with Studio Sound off the preview plays the original mic (cleaned volume \(v))")
            } else { check(false, "the preview has the cleaned and the original voice") }
            _ = await click("action-studio")
        }
        _ = await click("cleanup-all")
        check(p.edit?.removeFillers == false && p.edit?.shortenPauses == false, "Undo clean up turns them off")
        _ = await click("action-fillers")

        // Option-click a removed filler keeps it, and the cut list changes.
        let before = p.edit!.keeps(model.style).count
        if await click("word-\(filler.id)", modifiers: .option) {
            check(p.edit?.words[filler.id].override == false, "Option-click on '\(filler.text)' restores it")
            check((p.edit?.keeps(model.style).count ?? 0) != before, "the cut list changed")
        }
        // Click a normal word: the player jumps there (once the preview has caught up with the edit).
        // No waiting for the preview to rebuild after the edit: the click must still win.
        let word = edit.words.first { !$0.filler && $0.id > 5 }!
        if await click("word-\(word.id)") {
            try? await Task.sleep(for: .milliseconds(500))
            _ = await wait("preview rebuilt") { EditorRegistry.current?.building == false }
            try? await Task.sleep(for: .milliseconds(300))
            let t = model.selectedPlayerTime()
            let expect = p.edit.flatMap { _ in model.timelineComp(word.start) } ?? -1
            check(abs(t - expect) < 0.2, String(format: "clicking '%@' moves the playhead (%.2f vs %.2f)", word.text, t, expect))
        }
        await shot("after-word-click")

        // Shift-click selects a range, the Cut button cuts it.
        let a = word, b = edit.words[min(word.id + 2, edit.words.count - 1)]
        _ = await click("word-\(a.id)")
        _ = await click("word-\(b.id)", modifiers: .shift)
        if await click("Cut", role: "AXButton") {
            check(p.edit?.words[a.id].override == true && p.edit?.words[b.id].override == true, "Shift-select and Cut removes '\(a.text) ... \(b.text)'")
        }
        await shot("range-cut")
        _ = await click("Reset edits", role: "AXButton")
        check(p.edit?.words.allSatisfy { $0.override == nil } == true, "Reset edits clears every manual edit")

        // A pause chip toggles.
        if let g = p.edit?.gaps.first(where: { !$0.head && !$0.tail && $0.length >= 0.6 }) {
            let wasCut = p.edit!.isCut(g, model.style)
            if await click(String(format: "%.1fs", g.length)) {
                check(p.edit!.isCut(p.edit!.gaps[g.id], model.style) != wasCut, "clicking a pause chip flips it")
            }
            _ = await click("Reset edits", role: "AXButton")
        }

        // Inspector controls.
        _ = await click("Midnight")
        check(model.style.background == "midnight", "background wallpaper picks Midnight")
        _ = await wait("preview rebuilt", timeout: 20) { EditorRegistry.current?.building == false }
        try? await Task.sleep(for: .seconds(1))
        await shot("midnight")
        if let img = await previewFrame() {
            // Sample the preview just inside its top-left: it should be the midnight blue backdrop.
            let px = SelfTest.pixel(img, img.width * 3 / 100, img.height * 5 / 100)
            check(px.b > px.r + 12 && px.b > px.g + 8 && px.b > 40, "the preview redraws on the new background (pixel \(px))")
        } else { check(false, "the preview frame renders") }
        _ = await click("Sunset")
        check(model.style.background == "sunset", "background wallpaper picks Sunset")
        _ = await wait("preview rebuilt", timeout: 20) { EditorRegistry.current?.building == false }
        try? await Task.sleep(for: .seconds(1))
        await shot("sunset")
        if let img = await previewFrame() {
            let px = SelfTest.pixel(img, img.width * 3 / 100, img.height * 5 / 100)
            check(px.r > px.b + 30, "the preview redraws on the Sunset waves (pixel \(px))")
        } else { check(false, "the preview frame renders") }
        let zoomWas = model.style.autoZoom
        _ = await toggle("Zoom in where I click")
        check(model.style.autoZoom != zoomWas, "zoom toggle flips")
        check(Style.load() == model.style && Style.load().background == "sunset", "settings are saved the moment you change them (they come back next launch)")
        _ = await toggle("Zoom in where I click")
        let autoWas = model.style.autoCleanup
        _ = await toggle("Clean up new recordings automatically")
        check(model.style.autoCleanup != autoWas, "the automatic clean up toggle flips")
        _ = await toggle("Clean up new recordings automatically")
        _ = await click("1080p")
        check(model.style.resolution == 1080, "size picker sets 1080p")

        // Export through the button.
        let exportDir = out.appendingPathComponent("export")
        model.style.exportFolder = exportDir.path
        if await click("export") {
            check(model.exporting[p.folder] != nil || model.exported[p.folder] != nil, "Export starts")
            await shot("exporting")
            let done = await wait("export finishes", timeout: 600, { model.exported[p.folder] != nil || !model.message.isEmpty })
            if !model.message.isEmpty { check(false, "export error: \(model.message)") }
            print("    export progress at end: \(model.exporting[p.folder].map { String($0) } ?? "none")")
            if done, model.exported[p.folder] != nil {
                let url = model.exported[p.folder]!
                check(FileManager.default.fileExists(atPath: url.path), "exported file exists: \(url.lastPathComponent)")
            }
        }
        await shot("exported")

        // The New recording page.
        _ = await click("New recording")
        check(model.selection == nil, "the New recording button opens the record page")
        try? await Task.sleep(for: .seconds(1.5))
        check(find("record") != nil, "New recording shows the record button")
        await shot("record-page")
        check(model.hotKey?.registered == true, "Option-Command-R is registered as a global shortcut")
        model.style = style0

        if CommandLine.arguments.contains("--record-flow") {
            // The whole loop through the real buttons: record, stop (the shortcut's own action), process, edit.
            let before = Set(model.projects.map(\.folder))
            _ = await click("record")
            check(NSApp.windows.contains { $0.isVisible && $0.level == .screenSaver }, "the 3-2-1 countdown shows")
            _ = await wait("recording starts after the countdown", timeout: 15) { model.recording }
            let wallStart = Date()
            check(model.hud.pill?.isVisible == true, "the recording bar shows at the top of the screen")
            check(model.hud.pill?.sharingType == NSWindow.SharingType.none, "the recording bar is marked never to be captured")
            try? await Task.sleep(for: .seconds(2))
            check(LiveLevel.shared.levels.contains { $0 > 0.05 }, "the bar's level meter moves with the mic (\(LiveLevel.shared.levels.max() ?? 0))")
            if let v = model.hud.pill?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("recording-bar.png"))
            }
            if await click("Pause") {
                check(model.paused, "Pause pauses")
                let t = model.elapsed
                try? await Task.sleep(for: .seconds(2))
                check(abs(model.elapsed - t) < 0.3, "the timer stops while paused")
                _ = await click("Resume")
                check(!model.paused, "Resume carries on")
            }
            // Switch to another mic and back: each gets its own file, lined up later.
            let mic0 = model.micID
            if let other = model.microphones.first(where: { $0.uniqueID != mic0 }) {
                model.switchMic(other.uniqueID)
                try? await Task.sleep(for: .seconds(1.5))
                model.switchMic(mic0)
            }
            try? await Task.sleep(for: .seconds(1.5))
            let wall = Date().timeIntervalSince(wallStart)
            model.toggleRecording()
            check(model.hud.pill == nil, "the recording bar goes away on Stop")
            _ = await wait("a new recording appears", timeout: 20) { !Set(model.projects.map(\.folder)).subtracting(before).isEmpty }
            guard let new = model.projects.first(where: { !before.contains($0.folder) }) else { return }
            check(model.selection == new.folder.path, "the new recording opens")
            _ = await wait("it is processed", timeout: 180) { new.edit != nil || (!new.processing && !new.status.isEmpty) }
            check(new.edit != nil, "processing finished (\(new.status))")
            let len = (try? Processor.probeDuration(new.screen)) ?? 0
            check(abs(len - (wall - 2)) < 0.8, String(format: "the paused 2 s are left out of the video (%.1f s for %.1f s on the clock)", len, wall))
            let segs = new.events().micSegments.count
            check(segs >= 2 || model.microphones.count < 2, "switching mics mid-recording keeps both (\(segs) mic files)")
            // Neither the bar nor the red edge is in the recording: look at the video's top middle and its edges.
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: new.screen))
            if let frame = try? await g.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image {
                var red = 0, total = 0
                let w = frame.width, h = frame.height
                for x in stride(from: w / 2 - w / 5, to: w / 2 + w / 5, by: 6) {
                    for y in stride(from: 0, to: h / 12, by: 4) {
                        let px = SelfTest.pixel(frame, x, y); total += 1
                        if px.r > 200 && px.g < 80 && px.b < 80 { red += 1 }
                    }
                }
                for y in stride(from: 0, to: h, by: 8) {
                    for x in [1, w - 2] {
                        let px = SelfTest.pixel(frame, x, y); total += 1
                        if px.r > 200 && px.g < 80 && px.b < 80 { red += 1 }
                    }
                }
                check(red < total / 50, "the recording bar and red edge are not in the video (\(red) red of \(total) sampled)")
            } else { check(false, "a frame of the new recording reads") }
            _ = await wait("the editor shows it", timeout: 20) { find("Transcript") != nil }
            try? await Task.sleep(for: .seconds(2))
            await shot("new-recording")

            // Restart throws the take away (to the Trash) and counts down again.
            _ = await click("New recording")
            try? await Task.sleep(for: .seconds(1))
            _ = await click("record")
            _ = await wait("a second recording starts", timeout: 15) { model.recording }
            try? await Task.sleep(for: .seconds(1.5))
            let firstTake = Set(try! FileManager.default.contentsOfDirectory(atPath: Project.root.path))
            _ = await click("Restart")
            _ = await wait("it records again after the countdown", timeout: 15) {
                model.recording && Set((try? FileManager.default.contentsOfDirectory(atPath: Project.root.path)) ?? []) != firstTake
            }
            let now = Set((try? FileManager.default.contentsOfDirectory(atPath: Project.root.path)) ?? [])
            check(model.recording && firstTake.subtracting(now).count == 1, "Restart moves the take to the Trash and records a new one")
            try? await Task.sleep(for: .seconds(1.5))
            model.toggleRecording()
            _ = await wait("the restarted take is processed", timeout: 180) { model.selected?.edit != nil }
        }
    }
}

extension AppModel {
    // Small read-only hooks the UI test uses to check the player.
    func selectedPlayerTime() -> Double { EditorRegistry.current?.player.currentTime().seconds ?? -1 }
    func timelineComp(_ s: Double) -> Double? { EditorRegistry.current?.timeline.comp(forSource: s) }
}

@MainActor enum EditorRegistry { static weak var current: EditorState? }
