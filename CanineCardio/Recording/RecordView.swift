import Acquisition
import CardioCore
import SwiftUI

struct RecordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var micStatus = MicrophonePermission.status
    @State private var accelAxes: AxisSelection = .all

    private var session: MeasurementSession { model.session }

    var body: some View {
        @Bindable var session = model.session
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let err = model.storeError { banner(err, color: .red) }
                if case .failed(let message) = session.phase {
                    banner(message, color: .red) { session.dismissError() }
                }
                if session.configuration.recordAudio && micStatus == .denied {
                    micDeniedBanner
                }
                if !session.isMotionAvailable {
                    banner("No accelerometer detected. Run CanineCardio on a physical iPhone; the Simulator has no motion sensors.", color: .orange)
                }

                TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
                    LivePanel(session: session, accelAxes: accelAxes, tick: context.date)
                }

                Picker("Axes", selection: $accelAxes) {
                    ForEach(AxisSelection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                settings(session)
                controls
                if let saved = session.lastSaved, session.phase == .idle {
                    Text("Saved \(saved.id) · \(Fmt.duration(saved.recordedDurationS)) · \(saved.endReason.label)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Heart rate is not estimated in this version. This build records and exports raw signals so that their usefulness can be assessed first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Record")
        .onAppear { micStatus = MicrophonePermission.status }
    }

    // MARK: - Settings

    @ViewBuilder
    private func settings(_ session: MeasurementSession) -> some View {
        @Bindable var session = session
        let locked = session.phase.sensorsActive || session.phase == .saving
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Duration") {
                Picker("Duration", selection: $session.configuration.durationS) {
                    ForEach(MeasurementSession.Configuration.durationOptions, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            LabeledContent("Start delay") {
                Picker("Start delay", selection: $session.configuration.startDelayS) {
                    ForEach(MeasurementSession.Configuration.startDelayOptions, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            Toggle("Record microphone audio", isOn: $session.configuration.recordAudio)
            TextField("Label (subject, posture, phone position…)", text: $session.configuration.label)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
        .font(.callout)
        .disabled(locked)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            switch session.phase {
            case .idle, .failed:
                Button {
                    Task { await withPermission { session.startPreview() } }
                } label: {
                    Label("Preview", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                recordButton
            case .previewing:
                Button {
                    session.stopPreview()
                } label: {
                    Label("End preview", systemImage: "eye.slash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                recordButton
            case .countdown:
                stopButton(title: "Cancel")
            case .recording:
                stopButton(title: "Stop")
            case .saving:
                ProgressView("Saving…").frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
    }

    private var recordButton: some View {
        Button {
            Task { await withPermission { session.record() } }
        } label: {
            Label("Record", systemImage: "record.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!session.isMotionAvailable)
    }

    private func stopButton(title: String) -> some View {
        Button(role: .destructive) {
            session.stop()
        } label: {
            Label(title, systemImage: "stop.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    /// Requests microphone permission first if audio is enabled and permission is undetermined.
    private func withPermission(_ action: () -> Void) async {
        if session.configuration.recordAudio && MicrophonePermission.status == .undetermined {
            _ = await MicrophonePermission.request()
        }
        micStatus = MicrophonePermission.status
        if session.configuration.recordAudio && micStatus == .denied { return }
        action()
    }

    // MARK: - Banners

    private var micDeniedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Microphone access is off. Allow it in Settings, or turn off “Record microphone audio” to record motion only.")
            HStack {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Record motion only") { session.configuration.recordAudio = false }
            }
            .buttonStyle(.bordered)
        }
        .font(.footnote)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func banner(_ text: String, color: Color, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(.footnote)
            Spacer()
            if let dismiss {
                Button("Dismiss", action: dismiss).font(.footnote)
            }
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

enum AxisSelection: String, CaseIterable, Identifiable {
    case all, x, y, z
    var id: String { rawValue }
    var label: String { self == .all ? "XYZ" : rawValue.uppercased() }
    var channels: [Int] {
        switch self {
        case .all: [0, 1, 2]
        case .x: [0]
        case .y: [1]
        case .z: [2]
        }
    }
}

/// Everything redrawn at display rate. Reads snapshots from the ring buffers; sensor callbacks
/// never push to the UI.
private struct LivePanel: View {
    let session: MeasurementSession
    let accelAxes: AxisSelection
    let tick: Date

    private static let windowS = 5.0
    private static let axisColors: [Color] = [.red, .green, .blue]

    var body: some View {
        let status = session.liveStatus()
        let now = ProcessInfo.processInfo.systemUptime
        let accel = session.capture.accelerometerLive.snapshot(since: now - Self.windowS).decimated(buckets: 300).meanRemoved()
        let gyro = session.capture.gyroscopeLive.snapshot(since: now - Self.windowS).decimated(buckets: 300).meanRemoved()
        let audio = session.audioLive.snapshot(since: now - Self.windowS)

        VStack(alignment: .leading, spacing: 8) {
            header(status)
            Text("Acceleration (mean removed)").font(.caption).foregroundStyle(.secondary)
            WaveformView(times: accel.times,
                         series: accelAxes.channels.compactMap { ch in
                             accel.channels.indices.contains(ch) ? .init(values: accel.channels[ch], color: Self.axisColors[ch]) : nil
                         },
                         windowEnd: now, windowS: Self.windowS, minHalfRange: 0.002, unit: "mg", labelScale: 1000, symmetric: true)
                .frame(height: 150)
            Text("Rotation rate (mean removed)").font(.caption).foregroundStyle(.secondary)
            WaveformView(times: gyro.times,
                         series: accelAxes.channels.compactMap { ch in
                             gyro.channels.indices.contains(ch) ? .init(values: gyro.channels[ch], color: Self.axisColors[ch]) : nil
                         },
                         windowEnd: now, windowS: Self.windowS, minHalfRange: 0.005, unit: "rad/s", labelScale: 1, symmetric: true)
                .frame(height: 80)
            Text("Microphone level (10 ms RMS)").font(.caption).foregroundStyle(.secondary)
            WaveformView(times: audio.times,
                         series: audio.channels.isEmpty ? [] : [.init(values: audio.channels[0], color: .orange)],
                         windowEnd: now, windowS: Self.windowS, minHalfRange: 0.0005, unit: "FS", labelScale: 1, symmetric: false)
                .frame(height: 70)
            statusGrid(status)
        }
    }

    private func header(_ s: MeasurementSession.LiveStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseLabel).font(.caption.weight(.semibold)).foregroundStyle(phaseColor)
                Text(timerText(s)).font(.system(size: 40, weight: .medium, design: .monospaced))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Motion").font(.caption).foregroundStyle(.secondary)
                Label(s.motionLevel.label, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(s.motionLevel.color)
            }
        }
    }

    private func statusGrid(_ s: MeasurementSession.LiveStatus) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Accelerometer").foregroundStyle(.secondary)
                Text(Fmt.hz(s.accelerometerRateHz)).monospacedDigit()
                Text("\(s.recordedAccelerometer) rec").monospacedDigit().foregroundStyle(.secondary)
            }
            GridRow {
                Text("Gyroscope").foregroundStyle(.secondary)
                Text(Fmt.hz(s.gyroscopeRateHz)).monospacedDigit()
                Text("\(s.recordedGyroscope) rec").monospacedDigit().foregroundStyle(.secondary)
            }
            GridRow {
                Text("Microphone").foregroundStyle(.secondary)
                Text(Fmt.hz(s.audioSampleRateHz)).monospacedDigit()
                Text("\(s.audioFramesWritten) rec").monospacedDigit().foregroundStyle(.secondary)
            }
            if let err = s.sensorError {
                GridRow { Text("Sensor error: \(err)").foregroundStyle(.red).gridCellColumns(3) }
            }
        }
        .font(.caption)
    }

    private func timerText(_ s: MeasurementSession.LiveStatus) -> String {
        if let c = s.countdownRemainingS { return "−" + Fmt.clock(c.rounded(.up)) }
        if let e = s.elapsedS { return Fmt.clock(e) + " / " + Fmt.clock(session.configuration.durationS) }
        return Fmt.clock(0) + " / " + Fmt.clock(session.configuration.durationS)
    }

    private var phaseLabel: String {
        switch session.phase {
        case .idle: "IDLE"
        case .previewing: "PREVIEW · not recording"
        case .countdown: "STARTING · place the phone and keep still"
        case .recording: "● RECORDING"
        case .saving: "SAVING"
        case .failed: "ERROR"
        }
    }

    private var phaseColor: Color {
        switch session.phase {
        case .recording: .red
        case .countdown: .orange
        case .failed: .red
        default: .secondary
        }
    }
}
