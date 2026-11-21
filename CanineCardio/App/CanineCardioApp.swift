import Acquisition
import CardioCore
import Storage
import SwiftUI
import UIKit

@main
struct CanineCardioApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    // Core Motion stops delivering in the background, so a recording cannot
                    // continue; end it and record why rather than silently losing data.
                    if phase == .background {
                        model.session.interrupt("Recording ended because the app moved to the background.")
                    }
                }
                .onChange(of: model.session.phase.sensorsActive) { _, active in
                    UIApplication.shared.isIdleTimerDisabled = active
                }
        }
    }
}

/// Owns the long-lived objects. The production path always uses real device sensors.
@MainActor
@Observable
final class AppModel {
    let store: SessionStore
    let session: MeasurementSession
    let storeError: String?

    init() {
        var error: String?
        let store: SessionStore
        do {
            store = try SessionStore.defaultStore()
        } catch let e {
            error = "Local storage unavailable: \(e.localizedDescription)"
            store = SessionStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("Sessions"))
        }
        self.store = store
        self.storeError = error
        #if DEBUG
        DebugSelfTest.runIfRequested()
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        session = MeasurementSession(
            motion: CoreMotionSource(),
            audio: MicrophoneSource(),
            store: store,
            deviceInfo: DeviceInfo.current(systemName: UIDevice.current.systemName,
                                           systemVersion: UIDevice.current.systemVersion),
            appVersion: "\(version) (\(build))")
    }
}

enum AppTab: Hashable { case record, sessions, about }

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = DebugLaunchOptions.initialTab ?? .record

    var body: some View {
        TabView(selection: $tab) {
            Tab("Record", systemImage: "waveform.path.ecg", value: AppTab.record) {
                NavigationStack { RecordView() }
            }
            Tab("Sessions", systemImage: "list.bullet.rectangle", value: AppTab.sessions) {
                SessionListView(initialPath: DebugLaunchOptions.openSessionID.map { [$0] } ?? [])
            }
            Tab("About", systemImage: "info.circle", value: AppTab.about) {
                NavigationStack { AboutView() }
            }
        }
    }
}

/// DEBUG-only launch arguments used to screenshot screens in the Simulator:
/// `-CCTab sessions|about`, `-CCOpenSession <session id>`. Always nil in release builds.
enum DebugLaunchOptions {
    static var initialTab: AppTab? {
        #if DEBUG
        switch value(after: "-CCTab") {
        case "sessions": return .sessions
        case "about": return .about
        default: return nil
        }
        #else
        return nil
        #endif
    }

    static var openSessionID: String? {
        #if DEBUG
        return value(after: "-CCOpenSession")
        #else
        return nil
        #endif
    }

    /// `-CCAutoPreview`: start the live preview on launch (for device screenshots).
    static var autoPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-CCAutoPreview")
        #else
        return false
        #endif
    }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
