import SwiftUI
import AppKit
import AVFoundation

/// The mic's loudness while recording, apart from AppModel so its 20 updates a second only redraw the pill.
@MainActor final class LiveLevel: ObservableObject {
    static let shared = LiveLevel()
    @Published var levels: [Float] = Array(repeating: 0, count: 40)
    func push(_ v: Float) { levels.removeFirst(); levels.append(v) }
}

/// While recording: a pill at the top of the screen (time, live mic, mic picker, pause, restart, stop)
/// and a red edge around the recorded display. Both are Capture's own windows, and the recording
/// leaves Capture out, so neither appears in the video.
@MainActor final class RecordingHUD {
    private(set) var pill: NSPanel?
    private var border: NSPanel?

    func show(on screen: NSScreen) {
        hide()
        let p = panel(NSRect(x: 0, y: 0, width: 620, height: 52))
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: PillView().environmentObject(AppModel.shared).environmentObject(LiveLevel.shared))
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - 310, y: f.maxY - 52 - 10))
        p.orderFrontRegardless()
        pill = p

        let b = panel(screen.frame)
        b.ignoresMouseEvents = true
        b.contentView = NSHostingView(rootView: RecordingBorder().environmentObject(AppModel.shared))
        b.setFrame(screen.frame, display: true)
        b.orderFrontRegardless()
        border = b
    }

    func hide() {
        pill?.orderOut(nil); border?.orderOut(nil)
        pill = nil; border = nil
    }

    private func panel(_ rect: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.sharingType = .none   // never in a screen recording or screenshot (the recorder also excludes Capture)
        return p
    }
}

struct PillView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveLevel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if model.paused {
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                } else {
                    Circle().fill(.red).frame(width: 12, height: 12)
                        .opacity(pulse ? 0.35 : 1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                }
            }
            .frame(width: 16)
            Text(model.paused ? "Paused" : "REC").font(.system(size: 11, weight: .heavy)).foregroundStyle(model.paused ? .orange : .red)
            Text(model.elapsedText).font(.system(size: 16, weight: .semibold).monospacedDigit()).frame(minWidth: 52, alignment: .leading)

            LevelBars(levels: live.levels, dim: model.paused).frame(width: 96, height: 26)
                .help("Your microphone, live")

            Menu {
                ForEach(model.microphones, id: \.uniqueID) { m in
                    Button { model.switchMic(m.uniqueID) } label: {
                        if m.uniqueID == model.micID { Label(m.localizedName, systemImage: "checkmark") } else { Text(m.localizedName) }
                    }
                }
            } label: {
                Label(model.microphones.first { $0.uniqueID == model.micID }?.localizedName ?? "No microphone", systemImage: "mic.fill")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: 170)
            .help("Switch microphone")
            .accessibilityLabel("Microphone")

            Spacer(minLength: 0)
            Button { model.nameRecording() } label: {
                Image(systemName: "pencil").frame(width: 30, height: 30)
            }
            .help("Name this recording")
            .accessibilityLabel("Name this recording")
            Button { model.togglePause() } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 30, height: 30)
            }
            .help(model.paused ? "Resume (Option-Command-P)" : "Pause (Option-Command-P)")
            .accessibilityLabel(model.paused ? "Resume" : "Pause")
            Button { model.restartRecording() } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 30, height: 30)
            }
            .help("Restart: throw this take away and count down again")
            .accessibilityLabel("Restart")
            Button { model.toggleRecording() } label: {
                HStack(spacing: 5) { Image(systemName: "stop.fill"); Text("Stop").fontWeight(.semibold) }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(.red))
                    .foregroundStyle(.white)
            }
            .help("Stop (Option-Command-R)")
            .accessibilityLabel("Stop")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(width: 620, height: 52)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

struct LevelBars: View {
    let levels: [Float]
    var dim = false
    var body: some View {
        Canvas { ctx, size in
            let n = levels.count, w = size.width / CGFloat(n)
            for (i, v) in levels.enumerated() {
                let h = max(2, CGFloat(v) * size.height)
                let r = CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w - 1), height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(dim ? .gray : v > 0.92 ? .red : Color(red: 0.2, green: 0.85, blue: 0.4)))
            }
        }
    }
}

/// A red edge around the recorded screen: bright for a moment when recording starts, then steady.
struct RecordingBorder: View {
    @EnvironmentObject var model: AppModel
    @State private var flash = true
    var body: some View {
        Rectangle()
            .strokeBorder((model.paused ? Color.orange : Color.red).opacity(flash ? 1 : 0.75), lineWidth: flash ? 10 : 3)
            .animation(.easeOut(duration: 0.5), value: flash)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { flash = false } }
            .ignoresSafeArea()
    }
}

/// Listens to the chosen mic on the record page, so you can see it works before you start.
final class MicMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = MicMonitor()
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "capture.micmonitor")
    private var sum: Float = 0, count = 0

    func start(_ id: String) {
        stop()
        guard !id.isEmpty, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let dev = AVCaptureDevice(uniqueID: id), let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let s = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                             AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1]
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddInput(input), s.canAddOutput(out) else { return }
        s.addInput(input); s.addOutput(out)
        session = s
        queue.async { s.startRunning() }
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        queue.async { s.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { return }
        let f = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
        for i in 0..<(length / 4) { sum += f[i] * f[i] }
        count += length / 4
        if count >= 2400 {
            let rms = sqrt(sum / Float(count)); sum = 0; count = 0
            let v = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 60) / 50))
            Task { @MainActor in LiveLevel.shared.push(v) }
        }
    }
}
