import CardioCore
import Storage
import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [SessionSummary] = []
    @State private var incomplete: [URL] = []
    @State private var error: String?
    @State private var path: [String]

    init(initialPath: [String] = []) {
        _path = State(initialValue: initialPath)
    }

    var body: some View {
        NavigationStack(path: $path) { list }
    }

    private var list: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            if sessions.isEmpty && error == nil {
                ContentUnavailableView("No recordings", systemImage: "waveform",
                                       description: Text("Recordings appear here after they are saved. They are also visible in the Files app under On My iPhone › CanineCardio › Sessions."))
            }
            ForEach(sessions) { s in
                NavigationLink(value: s.id) { SessionRow(meta: s.metadata) }
            }
            .onDelete(perform: delete)
            if !incomplete.isEmpty {
                Section("Incomplete folders") {
                    Text("\(incomplete.count) folder(s) without metadata, probably from a recording that was cut off. They can be removed in the Files app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: String.self) { id in
            SessionDetailView(sessionID: id, onDelete: reload)
        }
        .onAppear(perform: reload)
        .onChange(of: model.session.lastSaved) { _, _ in reload() }
        .refreshable { reload() }
    }

    private func reload() {
        do {
            sessions = try model.store.list()
            incomplete = (try? model.store.incompleteSessionDirectories()) ?? []
            error = nil
        } catch {
            self.error = "Could not list sessions: \(error.localizedDescription)"
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            try? model.store.delete(id: sessions[i].id)
        }
        reload()
    }
}

private struct SessionRow: View {
    let meta: SessionMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(meta.label.isEmpty ? "Unlabelled" : meta.label).font(.headline)
                if meta.isSynthetic {
                    Text("SYNTHETIC").font(.caption2.bold()).padding(.horizontal, 4)
                        .background(.purple.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Text(Fmt.duration(meta.recordedDurationS)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(Fmt.dateTime.string(from: meta.createdAt)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("acc \(Fmt.hz(meta.accelerometer?.sampling.effectiveRateHz))")
                Text("gyr \(Fmt.hz(meta.gyroscope?.sampling.effectiveRateHz))")
                Text(meta.audio.map { "mic \(Fmt.hz($0.sampleRateHz))" } ?? "no audio")
                if meta.endReason != .completed { Text(meta.endReason.label).foregroundStyle(.orange) }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}
