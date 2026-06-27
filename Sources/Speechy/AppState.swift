import Combine
import Foundation

/// Phase of the dictation pipeline, drives the floaty UI.
enum DictationPhase: Equatable {
    case idle
    case loadingModel(progress: Double)
    case listening  // hold-to-talk: recording while key held
    case locked  // hands-free: recording until toggled off
    case transcribing
    case cleaning
    case pasting
    case error(String)
}

/// Shared, observable app state. The SwiftUI floaty binds to this.
/// All mutations happen on the main actor.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: DictationPhase = .idle
    @Published var audioLevel: Float = 0  // 0...1 RMS for the level meter
    @Published var lastText: String = ""
    @Published var modelReady: Bool = false
    @Published var hovering: Bool = false  // floaty hover → expanded hint

    /// Invoked when the floaty is clicked (click-to-start/stop). Set by AppDelegate.
    var onActivate: (() -> Void)?

    // Permission flags, refreshed by PermissionsManager.
    @Published var micGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    var isRecording: Bool {
        if case .listening = phase { return true }
        if case .locked = phase { return true }
        return false
    }
}
