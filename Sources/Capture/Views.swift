import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Recordings") {
                    ForEach(model.projects) { p in
                        ProjectRow(project: p).tag(p.folder.path)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Button { model.selection = nil } label: {
                    Label("New recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                if model.needsScreenPermission {
                    HStack {
                        Image(systemName: "lock.shield")
                        Text("Glyph Cast needs Screen Recording. Turn Glyph Cast on in the list (if it isn't there, drag it in from the Finder window), then click Reopen.")
                        Spacer()
                        Button("Open System Settings") { model.openScreenSettings() }.buttonStyle(.bordered)
                        Button("Reopen") { model.relaunch() }.buttonStyle(.borderedProminent)
                    }
                    .padding(10).background(.orange.opacity(0.15))
                }
                if !model.message.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(model.message).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { model.message = "" }
                    }
                    .padding(10).background(.orange.opacity(0.15))
                }
                if let p = model.selected {
                    EditorView(project: p).id(p.folder)
                } else {
                    RecordView()
                }
            }
        }
        .onAppear { model.refresh() }
    }
}

struct ProjectRow: View {
    @ObservedObject var project: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name).font(.body)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
    var subtitle: String {
        if project.processing { return project.status }
        if let e = project.edit { return duration(e.duration) }
        return project.status.isEmpty ? "Not processed" : "Needs processing"
    }
}

func duration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Record

struct RecordView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Record your screen").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Glyph Cast records the whole display and your voice. When you stop, it cleans the voice,\ncuts the ums and dead air, and frames the video.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                    GridRow {
                        Text("Display").foregroundStyle(.secondary)
                        Picker("Display", selection: $model.displayID) {
                            ForEach(model.displays, id: \.displayID) { d in Text(model.displayName(d)).tag(d.displayID) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Microphone").foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Picker("Microphone", selection: $model.micID) {
                                Text("None").tag("")
                                ForEach(model.microphones, id: \.uniqueID) { m in Text(m.localizedName).tag(m.uniqueID) }
                            }
                            .labelsHidden()
                            MicMeter().frame(width: 110, height: 26)
                        }
                    }
                    GridRow {
                        Text("System sound").foregroundStyle(.secondary)
                        Toggle("Record it too", isOn: $model.systemAudio)
                    }
                }
                .font(.title3)
                .padding(14)
            }
            .frame(width: 520)

            Button {
                model.toggleRecording()
            } label: {
                Label(model.starting ? "Starting..." : "Start recording", systemImage: "record.circle.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 28).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(model.starting)
            .accessibilityIdentifier("record")

            VStack(spacing: 8) {
                HStack(spacing: 18) {
                    Shortcut(keys: ["\u{2325}", "\u{2318}", "R"], what: "start and stop, from any app")
                    Shortcut(keys: ["\u{2325}", "\u{2318}", "P"], what: "pause")
                }
                Text("While you record, a bar at the top of the screen holds the time, your mic and the controls. It stays out of the video.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.refreshSources()
            if !model.micID.isEmpty, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            MicMonitor.shared.start(model.micID)
        }
        .onChange(of: model.micID) { MicMonitor.shared.start(model.micID) }
        .onDisappear { MicMonitor.shared.stop() }
    }
}

/// A keyboard shortcut drawn as keycaps, with what it does.
struct Shortcut: View {
    let keys: [String]
    let what: String
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { k in
                    Text(k).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.background.secondary))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                }
            }
            Text(what).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Option-Command-\(keys.last ?? ""): \(what)")
    }
}

struct MicMeter: View {
    @ObservedObject var live = LiveLevel.shared
    var body: some View { LevelBars(levels: live.levels).help("Your microphone, live: speak to check it") .accessibilityLabel("Microphone level") }
}

// MARK: - Editor

@MainActor
final class EditorState: ObservableObject {
    let player = AVPlayer()
    @Published var timeline = Timeline()
    @Published var currentWord: Int?
    @Published var building = false
    @Published var error = ""
    @Published var peaks: [Float] = []      // voice loudness, one value per Waveform.bucket seconds
    let playhead = Playhead()
    private var pending: Task<Void, Never>?
    private var observer: Any?
    private var words: [Word] = []
    private var clickedSource: Double?

    init() {
        EditorRegistry.current = self
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
    }

    private func tick(_ t: Double) {
        guard let s = timeline.source(at: t) else { if currentWord != nil { currentWord = nil }; return }
        if abs(playhead.source - s) > 0.01 { playhead.source = s }
        // Words are sorted: binary search for the one under the playhead.
        var lo = 0, hi = words.count - 1, found: Int?
        while lo <= hi {
            let m = (lo + hi) / 2
            if s < words[m].start { hi = m - 1 } else if s >= words[m].end { lo = m + 1 } else { found = words[m].id; break }
        }
        if found != currentWord { currentWord = found }
    }

    func rebuild(_ p: Project, _ style: Style, delay: Bool = true) {
        pending?.cancel()
        guard let edit = p.edit else { return }
        pending = Task {
            if delay { try? await Task.sleep(for: .milliseconds(350)) }
            if Task.isCancelled { return }
            building = true
            defer { building = false }
            do {
                let built = try await Composer.build(p, edit, style, height: 1080)
                if Task.isCancelled { return }
                let now = player.currentTime().seconds
                // First open: start on the recording itself, not the intro's opening frame.
                let src = timeline.segs.isEmpty ? built.timeline.segs.first { $0.kind == .main }?.src : timeline.source(at: now)
                let item = AVPlayerItem(asset: built.asset)
                item.videoComposition = built.video
                item.audioMix = built.audio
                let wasPlaying = player.rate > 0
                player.replaceCurrentItem(with: item)
                timeline = built.timeline
                words = edit.words
                // A paused player shows black until a seek lands on a ready item, so wait, then seek.
                for _ in 0..<50 where item.status != .readyToPlay { try? await Task.sleep(for: .milliseconds(50)) }
                // A word clicked while this was building wins over the old position.
                let target = clickedSource ?? src
                clickedSource = nil
                let t = target.flatMap { built.timeline.comp(forSource: $0) } ?? min(now, built.timeline.duration)
                await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
                error = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The waveform, and for a recording processed before Studio Sound had a slider, its original-mic file.
    func prepare(_ p: Project, _ style: Style) {
        guard peaks.isEmpty else { return }
        Task.detached {
            _ = p.energy()
            let made = !FileManager.default.fileExists(atPath: p.original.path) && (try? Processor.makeOriginal(p)) != nil
            let url = FileManager.default.fileExists(atPath: p.original.path) ? p.original : p.voice
            let v = Waveform.peaks(url)
            await MainActor.run {
                self.peaks = v
                if made { self.rebuild(p, style, delay: false) }
            }
        }
    }

    func seek(source s: Double) {
        if building { clickedSource = s }
        let t = timeline.comp(forSource: s) ?? timeline.segs.first { $0.kind == .main && $0.src >= s }?.comp
        guard let t else { return }
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// The source time under the playhead, on its own so ticking doesn't redraw the transcript.
final class Playhead: ObservableObject {
    @Published var source = 0.0
}

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var project: Project
    @StateObject private var state = EditorState()

    var body: some View {
        if let edit = project.edit {
            HSplitView {
                VSplitView {
                    VStack(spacing: 0) {
                        PlayerView(player: state.player)
                            .overlay(alignment: .topTrailing) {
                                if state.building { ProgressView().controlSize(.small).padding(10) }
                            }
                        Waveform(edit: edit, style: model.style, energy: project.energy(), peaks: state.peaks, playhead: state.playhead) { state.seek(source: $0) }
                            .frame(height: 64)
                    }
                    .frame(minHeight: 300, idealHeight: 560)
                    TranscriptView(project: project, state: state)
                        .frame(minHeight: 200)
                }
                .frame(minWidth: 600)
                Inspector(project: project, edit: edit)
                    .frame(minWidth: 320, idealWidth: 350, maxWidth: 420)
            }
            .onAppear { state.rebuild(project, model.style, delay: false); state.prepare(project, model.style) }
            .onChange(of: model.style) { state.rebuild(project, model.style) }
            .onChange(of: project.edit) { project.save(); state.rebuild(project, model.style) }
        } else {
            VStack(spacing: 18) {
                if project.processing {
                    ProgressView().controlSize(.large)
                    Text(project.status).font(.title2)
                    Text("Cleaning the voice, transcribing and finding the cuts. About a minute for every ten of recording.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(project.status.isEmpty ? "This recording has not been processed yet." : project.status)
                        .font(.title3).multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Process recording") { model.process(project) }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

// MARK: - Transcript

/// Descript-style: the words are the edit. Click a word to jump there; Option-click cuts or
/// restores it; Shift-click selects a range for the Cut and Restore buttons.
struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var project: Project
    @ObservedObject var state: EditorState
    @State private var anchor: Int?
    @State private var selection: ClosedRange<Int>?

    var body: some View {
        let edit = project.edit!
        let style = model.style
        VStack(alignment: .leading, spacing: 0) {
            CleanupBar(project: project, edit: edit)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            HStack(spacing: 12) {
                Text("Transcript").font(.title3.weight(.semibold))
                Text(summary(edit, style)).foregroundStyle(.secondary)
                Spacer()
                Button("Cut") { setSelection(true) }.disabled(selection == nil).keyboardShortcut(.delete, modifiers: [])
                Button("Restore") { setSelection(false) }.disabled(selection == nil)
                Button("Reset edits") {
                    var e = edit
                    for i in e.words.indices { e.words[i].override = nil }
                    for i in e.gaps.indices { e.gaps[i].override = nil }
                    project.edit = e
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(paragraphs(edit), id: \.self) { range in
                            FlowLayout(spacing: 4, lineSpacing: 6) {
                                ForEach(range, id: \.self) { i in
                                    if let g = gapBefore(edit, i, style) { GapChip(gap: g, cut: edit.isCut(g, style)) { toggleGap(g) } }
                                    wordView(edit, edit.words[i], style)
                                }
                                if range.upperBound == edit.words.count, let g = edit.gaps.first(where: { $0.tail }) {
                                    GapChip(gap: g, cut: edit.isCut(g, style)) { toggleGap(g) }
                                }
                            }
                        }
                        if edit.words.isEmpty { Text("No speech found in this recording.").foregroundStyle(.secondary) }
                    }
                    .padding(16)
                }
                .onChange(of: state.currentWord) {
                    if let w = state.currentWord, state.player.rate > 0 { withAnimation { proxy.scrollTo(w, anchor: .center) } }
                }
            }
        }
    }

    func summary(_ e: Edit, _ s: Style) -> String {
        let kept = e.keeps(s, project.energy()).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        return "\(duration(e.duration)) recorded, \(duration(kept)) after cuts"
    }

    func wordView(_ e: Edit, _ w: Word, _ s: Style) -> some View {
        let cut = e.isCut(w, s)
        let filler = e.fillerKind(w.id) != nil
        let selected = selection?.contains(w.id) == true
        let current = state.currentWord == w.id
        return Button { click(w) } label: { Text(w.text)
            .font(.system(size: 16))
            .strikethrough(cut, color: .red)
            .foregroundStyle(cut ? Color.secondary : filler ? Color.orange : Color.primary)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? AppModel.green.opacity(0.25) : current ? AppModel.green.opacity(0.12) : filler && !cut ? Color.orange.opacity(0.14) : .clear))
            .overlay(alignment: .bottom) { if current { Rectangle().fill(AppModel.green).frame(height: 2) } }
            .contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("word-\(w.id)")
            .contextMenu {
                Button(cut ? "Keep \"\(w.text)\"" : "Cut \"\(w.text)\"") { setWord(w.id, !cut) }
                if filler {
                    let same = e.words.filter { $0.bare == w.bare }
                    Button("Cut every \"\(w.bare)\" (\(same.count))") { setAll(w.bare, true) }
                    Button("Keep every \"\(w.bare)\"") { setAll(w.bare, false) }
                }
                Divider()
                Button("Play from here") { state.seek(source: w.start); state.player.play() }
            }
            .id(w.id)
            .help(filler ? "Filler word. Remove filler words takes these out; Option-click one to cut or keep it." : "Click to play from here. Option-click to cut.")
    }

    func click(_ w: Word) {
        let mods = UITest.modifiers ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if mods.contains(.option) {
            var e = project.edit!
            e.words[w.id].override = !e.isCut(w, model.style)
            project.edit = e
            return
        }
        if mods.contains(.shift), let a = anchor {
            selection = min(a, w.id)...max(a, w.id)
            return
        }
        anchor = w.id
        selection = w.id...w.id
        state.seek(source: w.start)
    }

    func setWord(_ id: Int, _ cut: Bool) {
        guard var e = project.edit else { return }
        e.words[id].override = cut
        project.edit = e
    }

    /// Every word spelled the same (all the "uh"s), cut or kept at once.
    func setAll(_ bare: String, _ cut: Bool) {
        guard var e = project.edit else { return }
        for i in e.words.indices where e.words[i].bare == bare { e.words[i].override = cut }
        project.edit = e
    }

    func setSelection(_ cut: Bool) {
        guard let r = selection, var e = project.edit else { return }
        for i in r { e.words[i].override = cut }
        // Pauses inside the selection go with it.
        for i in e.gaps.indices where e.gaps[i].afterWord >= r.lowerBound && e.gaps[i].afterWord < r.upperBound { e.gaps[i].override = cut }
        project.edit = e
        selection = nil
    }

    func toggleGap(_ g: Gap) {
        var e = project.edit!
        e.gaps[g.id].override = !e.isCut(g, model.style)
        project.edit = e
    }

    func gapBefore(_ e: Edit, _ i: Int, _ s: Style) -> Gap? {
        e.gaps.first { $0.afterWord == i - 1 && ($0.length >= 0.6 || $0.override != nil) }
    }

    /// Paragraphs break at long pauses, or after a sentence once a paragraph is long.
    func paragraphs(_ e: Edit) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for (i, w) in e.words.enumerated() where i > start {
            let gap = w.start - e.words[i - 1].end
            let sentence = e.words[i - 1].text.hasSuffix(".") || e.words[i - 1].text.hasSuffix("?")
            if gap > 2.0 || (sentence && i - start > 45) { out.append(start..<i); start = i }
        }
        if start < e.words.count { out.append(start..<e.words.count) }
        return out
    }
}

struct GapChip: View {
    let gap: Gap
    let cut: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(String(format: "%.1fs", gap.length))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .strikethrough(cut, color: .red)
            .foregroundStyle(cut ? Color.secondary : Color.primary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().stroke(cut ? Color.red.opacity(0.5) : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule()) }
            .buttonStyle(.plain)
            .help(gap.screenBusy ? "Pause while the screen was moving. Click to cut or keep." : "Pause. Click to cut or keep.")
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + lineSpacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var project: Project
    let edit: Edit

    var body: some View {
        Form {
            Section("Export") {
                Picker("Size", selection: $model.style.resolution) {
                    Text("1080p").tag(1080)
                    Text("1440p").tag(1440)
                    Text("4K").tag(2160)
                }
                .pickerStyle(.segmented)
                LabeledContent("Save to") {
                    HStack {
                        Text(abbreviate(model.style.exportFolder)).lineLimit(1).truncationMode(.middle)
                        Button("Choose") { if let f = pickFolder() { model.style.exportFolder = f } }
                    }
                }
                if let f = model.exporting[project.folder] {
                    ProgressView(value: f) { Text("Exporting \(Int(f * 100))%") }
                } else {
                    Button {
                        model.export(project)
                    } label: {
                        Label("Export MP4", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("export")
                }
                if let url = model.exported[project.folder] {
                    LabeledContent("Saved") {
                        Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.link)
                    }
                }
            }

            Section("Clean up") {
                Toggle("Clean up new recordings automatically", isOn: $model.style.autoCleanup)
                Text("Removes filler words, shortens pauses and turns on Studio Sound as soon as a recording is ready. Off: you choose above the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Frame") {
                BackgroundPicker(style: $model.style)
                if model.style.background != "none" {
                    LabeledContent("Padding") { Slider(value: $model.style.padding, in: 0...0.15) }
                    LabeledContent("Corners") { Slider(value: $model.style.radius, in: 0...0.03) }
                    Toggle("Shadow", isOn: $model.style.shadow)
                }
            }

            Section("Zoom") {
                Toggle("Zoom in where I click", isOn: $model.style.autoZoom)
                if model.style.autoZoom {
                    LabeledContent("Amount") {
                        HStack {
                            Slider(value: $model.style.zoomAmount, in: 1.2...2.5, step: 0.1)
                            Text(String(format: "%.1fx", model.style.zoomAmount)).monospacedDigit().frame(width: 40)
                        }
                    }
                }
                Toggle("Show clicks", isOn: $model.style.clickRings)
            }

            Section("Intro and outro") {
                ClipRow(title: "Intro", on: $model.style.intro, path: $model.style.introPath)
                ClipRow(title: "Outro", on: $model.style.outro, path: $model.style.outroPath)
            }

            Section("Recording") {
                Button("Show files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.screen]) }
                Button("Process again") { project.edit = nil; model.process(project) }
            }
        }
        .formStyle(.grouped)
    }
}

struct BackgroundPicker: View {
    @Binding var style: Style
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Composer.wallpapers, id: \.id) { w in
                    swatch(w.id, w.name) {
                        if let img = NSImage(contentsOf: Composer.wallpaper(w.id, thumb: true)) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else { Color.gray }
                    }
                }
                swatch("wallpaper", "My desktop picture") { tile("photo", "Desktop") }
                swatch("image", "Choose an image") { tile("folder", style.imagePath.isEmpty ? "Image" : (style.imagePath as NSString).lastPathComponent) }
                swatch("none", "No frame: the screen fills the video") { tile("rectangle.dashed", "None") }
            }
        }
    }

    func tile(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
            Text(label).font(.caption2).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
    }

    func swatch<V: View>(_ id: String, _ name: String, @ViewBuilder _ fill: () -> V) -> some View {
        Button {
            if id == "image" {
                guard let p = pickFile([.image]) else { return }
                style.imagePath = p
            }
            style.background = id
        } label: {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .overlay(fill())
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.background == id ? AppModel.green : .secondary.opacity(0.3), lineWidth: style.background == id ? 3 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

struct ClipRow: View {
    let title: String
    @Binding var on: Bool
    @Binding var path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $on)
            HStack {
                Text(path.isEmpty ? "No file chosen" : (path as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose") { if let p = pickFile([.movie]) { path = p; on = true } }
            }
        }
    }
}

func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

@MainActor func pickFile(_ types: [UTType]) -> String? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = types
    return panel.runModal() == .OK ? panel.url?.path : nil
}

@MainActor func pickFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}

// MARK: - Cleanup actions (Descript-style: one click each, undo by clicking again)

struct CleanupBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var project: Project
    let edit: Edit

    var body: some View {
        let style = model.style
        let fillerCount = edit.fillerKinds.reduce(0) { $0 + edit.fillers($1).count }
        let pauseCount = edit.longPauses(style).count
        let all = edit.removeFillers && edit.shortenPauses && edit.studioSound
        FlowLayout(spacing: 8, lineSpacing: 8) {
            Button {
                change { $0.removeFillers = !all; $0.shortenPauses = !all; $0.studioSound = true }
            } label: {
                Label(all ? "Undo clean up" : "Clean up everything", systemImage: all ? "arrow.uturn.backward" : "wand.and.stars")
            }
            .buttonStyle(.borderedProminent).tint(all ? .gray : AppModel.green)
            .help("Remove filler words, shorten long pauses and turn on Studio Sound, in one click")
            .accessibilityIdentifier("cleanup-all")

            ActionToggle(title: "Remove filler words", icon: "text.badge.minus", count: fillerCount,
                         on: edit.removeFillers, id: "action-fillers") {
                change { $0.removeFillers.toggle() }
            } options: {
                Text("Remove filler words").font(.headline)
                ForEach(Edit.kinds, id: \.id) { k in
                    Toggle(isOn: Binding(get: { edit.fillerKinds.contains(k.id) }, set: { on in
                        change { e in e.fillerKinds = Edit.kinds.map(\.id).filter { $0 == k.id ? on : e.fillerKinds.contains($0) } }
                    })) {
                        HStack { Text(k.name); Spacer(); Text("\(edit.fillers(k.id).count)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                Text("Words you Option-click keep your choice either way.").font(.caption).foregroundStyle(.secondary)
            }

            ActionToggle(title: "Shorten pauses", icon: "scissors", count: pauseCount,
                         on: edit.shortenPauses, id: "action-pauses") {
                change { $0.shortenPauses.toggle() }
            } options: {
                Text("Shorten pauses").font(.headline)
                HStack {
                    Text("Longer than")
                    Slider(value: $model.style.maxPause, in: 0.4...3, step: 0.1).frame(width: 140)
                    Text(String(format: "%.1fs", style.maxPause)).monospacedDigit().frame(width: 40)
                }
                Toggle("Keep pauses while the screen is moving", isOn: $model.style.keepBusyPauses)
                Text("Each long pause is cut down to \(String(format: "%.2f", style.keepPause))s. Dead air at the start and end is always trimmed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            ActionToggle(title: "Studio Sound", icon: "waveform", count: nil,
                         on: edit.studioSound, id: "action-studio") {
                change { $0.studioSound.toggle() }
            } options: {
                Text("Studio Sound").font(.headline)
                HStack {
                    Text("Intensity")
                    Slider(value: Binding(get: { edit.studioAmount }, set: { v in change { $0.studioAmount = v } }), in: 0.2...1, step: 0.05).frame(width: 140)
                    Text("\(Int(edit.studioAmount * 100))%").monospacedDigit().frame(width: 40)
                }
                Text("Background noise removed, voice shaped and leveled to -14 LUFS. Lower blends in your original mic.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func change(_ f: (inout Edit) -> Void) {
        guard var e = project.edit else { return }
        f(&e)
        project.edit = e
    }
}

/// A switch-like button with a count, and a chevron that opens its options.
struct ActionToggle<Options: View>: View {
    let title: String
    let icon: String
    let count: Int?
    let on: Bool
    let id: String
    let action: () -> Void
    @ViewBuilder let options: () -> Options
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: on ? "checkmark.circle.fill" : icon)
                    Text(title).lineLimit(1).fixedSize()
                    if let count { Text("\(count)").monospacedDigit().padding(.horizontal, 6).background(Capsule().fill(.quaternary)) }
                }
                .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
            .accessibilityLabel(title)
            .accessibilityValue(on ? "on" : "off")
            .help(on ? "On. Click to undo." : "Click to apply")
            Divider().frame(height: 18)
            Button { showOptions.toggle() } label: {
                Image(systemName: "chevron.down").font(.caption).padding(.horizontal, 7).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) options")
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) { options() }.padding(16).frame(width: 340)
            }
        }
        .foregroundStyle(on ? AppModel.green : Color.primary)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? AppModel.green.opacity(0.14) : Color.secondary.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? AppModel.green.opacity(0.6) : Color.secondary.opacity(0.25)))
    }
}

// MARK: - Waveform timeline

/// The whole recording as a waveform: cut stretches dimmed with a red wash, the playhead in green.
/// Click anywhere to play from there.
struct Waveform: View {
    static let bucket = 0.05
    let edit: Edit
    let style: Style
    let energy: Energy?
    let peaks: [Float]
    @ObservedObject var playhead: Playhead
    let seek: (Double) -> Void

    var body: some View {
        let cuts = edit.cuts(style, energy)
        GeometryReader { geo in
            Canvas { ctx, size in
                let d = max(edit.duration, 0.1)
                func x(_ t: Double) -> CGFloat { CGFloat(t / d) * size.width }
                let mid = size.height / 2
                for c in cuts {
                    ctx.fill(Path(CGRect(x: x(c.lowerBound), y: 0, width: max(1, x(c.upperBound) - x(c.lowerBound)), height: size.height)),
                             with: .color(.red.opacity(0.16)))
                }
                if !peaks.isEmpty {
                    let cols = Int(size.width / 2)
                    for i in 0..<max(cols, 1) {
                        let a = i * peaks.count / cols, b = max(a + 1, (i + 1) * peaks.count / cols)
                        let v = CGFloat(peaks[a..<min(b, peaks.count)].max() ?? 0)
                        let t = (Double(i) + 0.5) / Double(cols) * d
                        let isCut = cuts.contains { $0.contains(t) }
                        let h = max(1, v * (size.height - 8))
                        ctx.fill(Path(CGRect(x: CGFloat(i) * 2, y: mid - h / 2, width: 1.4, height: h)),
                                 with: .color(isCut ? .red.opacity(0.45) : AppModel.green.opacity(0.85)))
                    }
                }
                ctx.fill(Path(CGRect(x: x(playhead.source) - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in seek(Double(p.x / max(geo.size.width, 1)) * edit.duration) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.25))
        .accessibilityLabel("Waveform")
    }

    /// How loud each bucket is, as 0...1.
    nonisolated static func peaks(_ url: URL) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536) else { return [] }
        let per = max(1, Int(f.processingFormat.sampleRate * bucket))
        var out: [Float] = [], cur: Float = 0, n = 0
        while (try? f.read(into: buf)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(buf.frameLength) {
                cur += ch[i] * ch[i]; n += 1
                if n == per { out.append(sqrt(cur / Float(n))); cur = 0; n = 0 }
            }
        }
        if n > 0 { out.append(sqrt(cur / Float(n))) }
        // Loudness (RMS) in decibels, -55 to -10 dB, so syllables, breaths and pauses read apart.
        return out.map { max(0, min(1, (20 * log10(max($0, 1e-6)) + 55) / 45)) }
    }
}
