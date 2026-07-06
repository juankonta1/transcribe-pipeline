import SwiftUI
import UniformTypeIdentifiers

struct DropView: View {
    @ObservedObject var recorder = Recorder.shared
    @ObservedObject var calendar = CalendarWatcher.shared
    @State private var context = ""
    @State private var droppedFile: URL?
    @State private var targeted = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ---- Recording controls ----
            HStack {
                if recorder.isRecording {
                    Label(recorder.elapsed, systemImage: "record.circle.fill")
                        .foregroundStyle(.red).monospacedDigit()
                    Spacer()
                    Button("Stop & Transcribe") {
                        Task { await stopRecording() }
                    }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button {
                        Task {
                            do { try await recorder.start() }
                            catch { status = "Record failed: \(error.localizedDescription)" }
                        }
                    } label: {
                        Label("Record call", systemImage: "record.circle")
                    }
                    Spacer()
                    if let next = calendar.nextCall {
                        Text(next).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // ---- Drop zone ----
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
                    .frame(height: 64)
                if let f = droppedFile {
                    Label(f.lastPathComponent, systemImage: "waveform")
                        .lineLimit(1).padding(.horizontal, 8)
                } else {
                    Text("Drop a call recording here")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { droppedFile = url; status = "" } }
                }
                return true
            }

            // ---- Context ----
            Text("Context (people, company, topics — helps fix names)")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $context)
                .frame(height: 60)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.secondary.opacity(0.3)))

            HStack {
                Button("Transcribe") { submitDrop() }
                    .buttonStyle(.borderedProminent)
                    .disabled(droppedFile == nil)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            Divider()
            HStack {
                Button("Transcripts folder") {
                    NSWorkspace.shared.open(INBOX.deletingLastPathComponent())
                }.buttonStyle(.link).font(.caption)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func submitDrop() {
        guard let src = droppedFile else { return }
        do {
            let dest = INBOX.appendingPathComponent(src.lastPathComponent)
            try FileManager.default.createDirectory(at: INBOX, withIntermediateDirectories: true)
            try writeMeta(stem: src.deletingPathExtension().lastPathComponent,
                          context: context, channels: "mixed", title: nil)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: src, to: dest)
            status = "Sent \(src.lastPathComponent) ✓"
            droppedFile = nil
            context = ""
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        do {
            try await recorder.stop(context: context)
            status = "Recording sent to transcription ✓"
            context = ""
        } catch {
            status = "Stop failed: \(error.localizedDescription)"
        }
    }
}

func writeMeta(stem: String, context: String, channels: String, title: String?) throws {
    var meta: [String: String] = ["channels": channels]
    if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        meta["context"] = context
    }
    if let title { meta["title"] = title }
    let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
    try data.write(to: INBOX.appendingPathComponent(stem + ".meta.json"))
}
