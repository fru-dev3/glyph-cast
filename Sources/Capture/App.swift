import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Carbon.HIToolbox
import os

struct CaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Glyph Cast", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
                .tint(AppModel.green)
        }
        .defaultSize(width: 1440, height: 900)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            if model.recording {
                Label(model.elapsedText, systemImage: "record.circle.fill")
            } else {
                Image(systemName: "record.circle")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // scripts/install-mac.sh reads this line to confirm an update kept both permissions.
        let screen = CGPreflightScreenCaptureAccess()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Logger(subsystem: "dev.fru.capture", category: "app").notice("permissions: screen=\(screen, privacy: .public) mic=\(mic, privacy: .public) version=\(version, privacy: .public)")
        // `--appearance dark|light`: screenshots of both looks without touching the system setting.
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.recording {
            Button("Stop Recording  (\(model.elapsedText))") { model.toggleRecording() }
            Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
        } else {
            Button("Start Recording") { model.toggleRecording() }
        }
        Menu("Microphone") {
            ForEach(model.microphones, id: \.uniqueID) { m in
                Button { model.switchMic(m.uniqueID) } label: {
                    if m.uniqueID == model.micID { Label(m.localizedName, systemImage: "checkmark") } else { Text(m.localizedName) }
                }
            }
        }
        Text("Option-Command-R: start and stop.  Option-Command-P: pause.")
        Divider()
        Button("Open Glyph Cast") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Glyph Cast") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let green = Color(red: 0, green: 0.5, blue: 0)

    @Published var style = Style.load() { didSet { if style != oldValue { style.save() } } }
    @Published var projects: [Project] = []
    @Published var selection: String?          // nil = the record page
    @Published var recording = false
    @Published var paused = false
    @Published var starting = false
    @Published var countdown = 0
    @Published var elapsed: TimeInterval = 0
    @Published var message = ""
    @Published var displays: [SCDisplay] = []
    @Published var needsScreenPermission = false
    @Published var displayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var microphones: [AVCaptureDevice] = []
    @Published var micID = UserDefaults.standard.string(forKey: "micID") ?? "" { didSet { UserDefaults.standard.set(micID, forKey: "micID") } }
    @Published var systemAudio = UserDefaults.standard.bool(forKey: "systemAudio") { didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudio") } }
    @Published var exporting: [URL: Double] = [:]
    @Published var exported: [URL: URL] = [:]

    private let recorder = Recorder()
    private(set) var hotKey: HotKey?
    private(set) var pauseHotKey: HotKey?
    let hud = RecordingHUD()
    private var pausedFor: TimeInterval = 0
    private var pauseBegan: Date?
    private var recordingFolder: URL?
    private var timer: Timer?
    private var startedAt = Date()
    private var cache: [URL: Project] = [:]
    private var countdownPanel: NSPanel?

    var elapsedText: String {
        let s = Int(elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var selected: Project? { projects.first { $0.folder.path == selection } }

    init() {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in self?.toggleRecording() }
        pauseHotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in self?.togglePause() }
        recorder.onLevel = { v in Task { @MainActor in LiveLevel.shared.push(v) } }
        recorder.onFailure = { [weak self] msg in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.message = "Recording stopped: \(msg)"
                self.stopRecording()
            }
        }
        refresh()
        Task { await refreshSources() }
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
            selection = URL(fileURLWithPath: CommandLine.arguments[i + 1]).path
        }
        DispatchQueue.main.async { UITest.start() }
    }

    func refresh() {
        projects = Project.all().map { p in
            if let c = cache[p.folder] { return c }
            cache[p.folder] = p
            return p
        }
    }

    func refreshSources() async {
        microphones = Recorder.microphones()
        if micID.isEmpty || !microphones.contains(where: { $0.uniqueID == micID }) {
            micID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID ?? ""
        }
        // Without Screen Recording permission macOS lists no displays and refuses to record.
        // Asking once puts Capture in System Settings with its switch, and shows the system prompt.
        if !CGPreflightScreenCaptureAccess() {
            needsScreenPermission = true
            CGRequestScreenCaptureAccess()
            return
        }
        needsScreenPermission = false
        displays = (try? await Recorder.displays()) ?? []
        if !displays.contains(where: { $0.displayID == displayID }), let d = displays.first { displayID = d.displayID }
    }

    /// The system prompt is dropped when Capture isn't in front, so this also shows Capture.app
    /// in Finder: dragging it into the Settings list works every time.
    func openScreenSettings() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// macOS only applies a new Screen Recording grant to a fresh process.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    func displayName(_ d: SCDisplay) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }
        return "\(screen?.localizedName ?? "Display") (\(d.width)x\(d.height))"
    }

    // MARK: recording

    func toggleRecording() {
        if recording { stopRecording() } else if !starting { startRecording() }
    }

    func startRecording() {
        let missing = Tools.missing()
        if !missing.isEmpty { message = "Install first: " + missing.joined(separator: ", "); return }
        if !CGPreflightScreenCaptureAccess() { needsScreenPermission = true; CGRequestScreenCaptureAccess(); return }
        starting = true
        message = ""
        Task {
            if !micID.isEmpty, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            MicMonitor.shared.stop()
            // Put the window away, count down, then hand focus back to whatever was in front.
            for w in NSApp.windows where w.isVisible && !(w is NSPanel) && w.frame.width > 400 { w.orderOut(nil) }
            for n in [3, 2, 1] {
                showCountdown(n)
                try? await Task.sleep(for: .milliseconds(800))
            }
            showCountdown(0)
            NSApp.hide(nil)
            var made: URL?
            do {
                let folder = try Project.newFolder()
                made = folder
                let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && !micID.isEmpty ? micID : nil
                try await recorder.start(displayID: displayID, micID: mic, systemAudio: systemAudio, folder: folder)
                recording = true
                paused = false
                recordingFolder = folder
                startedAt = Date()
                pausedFor = 0; pauseBegan = nil
                elapsed = 0
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        let still = self.pauseBegan.map { Date().timeIntervalSince($0) } ?? 0
                        self.elapsed = Date().timeIntervalSince(self.startedAt) - self.pausedFor - still
                    }
                }
                if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) ?? NSScreen.main {
                    hud.show(on: screen)
                }
            } catch {
                // Leave no empty recording folder behind.
                if let made, (try? FileManager.default.contentsOfDirectory(atPath: made.path))?.isEmpty == true { try? FileManager.default.removeItem(at: made) }
                message = "Could not start: \(error.localizedDescription)"
                showWindow()
            }
            starting = false
        }
    }

    func togglePause() {
        guard recording else { return }
        if paused {
            recorder.resume()
            if let b = pauseBegan { pausedFor += Date().timeIntervalSince(b) }
            pauseBegan = nil
        } else {
            recorder.pause()
            pauseBegan = Date()
        }
        paused.toggle()
    }

    /// Switch microphones; mid-recording the new mic takes over from this moment.
    func switchMic(_ id: String) {
        guard id != micID else { return }
        micID = id
        guard recording else { return }
        Task {
            do { try await recorder.switchMicrophone(id) } catch { message = "Could not switch microphone: \(error.localizedDescription)" }
        }
    }

    /// Throw the take away (to the Trash, so it can still be recovered) and count down again.
    func restartRecording() {
        guard recording else { return }
        let folder = recordingFolder
        finishRecording()
        Task {
            _ = try? await recorder.stop()
            if let folder { _ = try? await NSWorkspace.shared.recycle([folder]) }
            refresh()
            startRecording()
        }
    }

    private func finishRecording() {
        recording = false
        paused = false
        timer?.invalidate()
        hud.hide()
        LiveLevel.shared.levels = Array(repeating: 0, count: 40)
    }

    func stopRecording() {
        guard recording else { return }
        finishRecording()
        Task {
            do {
                let ev = try await recorder.stop()
                refresh()
                if let folder = projects.first?.folder, ev.duration > 0 {
                    selection = folder.path
                    if let p = selected { process(p) }
                }
            } catch {
                message = "Recording failed: \(error.localizedDescription)"
            }
            showWindow()
        }
    }

    func showWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Glyph Cast" }?.makeKeyAndOrderFront(nil)
    }

    private func showCountdown(_ n: Int) {
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        guard n > 0 else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView:
            Text("\(n)").font(.system(size: 120, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 220, height: 220).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 44)))
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID } ?? NSScreen.main
        if let f = screen?.frame { panel.setFrameOrigin(NSPoint(x: f.midX - 110, y: f.midY - 110)) }
        panel.orderFrontRegardless()
        countdownPanel = panel
    }

    // MARK: processing and export

    func process(_ p: Project) {
        guard !p.processing else { return }
        p.processing = true
        p.status = "Starting"
        Task.detached {
            do {
                let edit = try await Processor.process(p) { s in Task { @MainActor in p.status = s } }
                await MainActor.run { p.edit = edit; p.processing = false; p.status = "" }
            } catch {
                await MainActor.run { p.processing = false; p.status = "Processing failed: \(error.localizedDescription)" }
            }
        }
    }

    func export(_ p: Project) {
        guard let edit = p.edit, exporting[p.folder] == nil else { return }
        exporting[p.folder] = 0
        exported[p.folder] = nil
        let style = self.style
        Task.detached {
            do {
                let url = try await Composer.export(p, edit, style) { f in Task { @MainActor in AppModel.shared.exporting[p.folder] = f } }
                await MainActor.run { AppModel.shared.exporting[p.folder] = nil; AppModel.shared.exported[p.folder] = url }
            } catch {
                await MainActor.run {
                    AppModel.shared.exporting[p.folder] = nil
                    AppModel.shared.message = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
