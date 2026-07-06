import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit

/// Receives system-audio sample buffers off the main actor and writes sys.caf.
/// Only ever touched from the SCStream sample-handler queue (and closed via
/// queue.sync from stop()), so plain unsynchronized state is fine.
final class SystemAudioWriter: NSObject, SCStreamOutput {
    private let dir: URL
    private var file: AVAudioFile?

    init(dir: URL) { self.dir = dir }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        if file == nil {
            file = try? AVAudioFile(forWriting: dir.appendingPathComponent("sys.caf"),
                                    settings: format.settings)
        }
        try? file?.write(from: pcm)
    }

    func close() { file = nil }
}

/// Records the user's mic and system audio (everyone else on the call) to two
/// separate tracks, then merges them into a stereo m4a (L = mic/You, R = system/Them)
/// and drops it in the transcription inbox with a channels=split sidecar.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published var isRecording = false
    @Published var elapsed = "0:00"
    var pendingTitle: String?

    private var engine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var stream: SCStream?
    private var sysWriter: SystemAudioWriter?
    private var workDir: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private let audioQueue = DispatchQueue(label: "calldrop.sysaudio")

    func start() async throws {
        guard !isRecording else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calldrop-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir

        // --- mic ---
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        let micFile = try AVAudioFile(forWriting: dir.appendingPathComponent("mic.caf"),
                                      settings: micFormat.settings)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buf, _ in
            try? micFile.write(from: buf)
        }
        try engine.start()
        self.engine = engine
        self.micFile = micFile

        // --- system audio ---
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "CallDrop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = SystemAudioWriter(dir: dir)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
        self.sysWriter = writer

        startedAt = Date()
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                let t = Int(Date().timeIntervalSince(s))
                self.elapsed = String(format: "%d:%02d", t / 60, t % 60)
            }
        }
    }

    func stop(context: String) async throws {
        guard isRecording, let dir = workDir else { return }
        isRecording = false
        timer?.invalidate()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        micFile = nil
        try? await stream?.stopCapture()
        stream = nil
        let writer = sysWriter
        audioQueue.sync { writer?.close() }  // flush after the last buffer
        sysWriter = nil

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let title = pendingTitle ?? "Call \(stamp.string(from: startedAt ?? Date()))"
        pendingTitle = nil
        let safeName = title.replacingOccurrences(of: "/", with: "-")
        let merged = dir.appendingPathComponent(safeName + ".m4a")

        // L = mic (You), R = system (Them)
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ffmpeg.arguments = [
            "-y", "-v", "error",
            "-i", dir.appendingPathComponent("mic.caf").path,
            "-i", dir.appendingPathComponent("sys.caf").path,
            "-filter_complex",
            "[0]aresample=48000,pan=mono|c0=c0[m];" +
            "[1]aresample=48000,pan=mono|c0=0.5*c0+0.5*c1[s];" +
            "[m][s]join=inputs=2:channel_layout=stereo[out]",
            "-map", "[out]", "-c:a", "aac", "-b:a", "128k", merged.path,
        ]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        guard ffmpeg.terminationStatus == 0 else {
            NSWorkspace.shared.open(dir)  // don't lose the raw tracks
            throw NSError(domain: "CallDrop", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Merge failed — raw tracks kept in \(dir.lastPathComponent)"])
        }

        try FileManager.default.createDirectory(at: INBOX, withIntermediateDirectories: true)
        try writeMeta(stem: safeName, context: context, channels: "split", title: title)
        try FileManager.default.moveItem(
            at: merged, to: INBOX.appendingPathComponent(merged.lastPathComponent))
        try? FileManager.default.removeItem(at: dir)
        workDir = nil
    }
}
