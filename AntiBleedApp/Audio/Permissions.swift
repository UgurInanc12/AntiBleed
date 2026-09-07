import Foundation
import AntiBleedCore
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AppKit)
import AppKit
#endif

public enum PermissionState: String {
    case notDetermined = "Not determined"
    case granted = "Granted"
    case denied = "Denied"
    case restricted = "Restricted"
}

/// Microphone and system-audio permissions (PLAN 26, Phase 1/2).
/// Rules: request only on explicit user action; never spam prompts; when denied
/// the pipeline keeps working with raw mic / silence, never crashes.
public final class Permissions: ObservableObject {
    @Published public private(set) var mic: PermissionState = .notDetermined
    /// macOS has no query API for the system-audio (tap) permission. It is
    /// requested implicitly the first time the aggregate with a tap starts I/O,
    /// so we infer it from the capture result and persist the last outcome.
    @Published public private(set) var systemAudio: PermissionState = .notDetermined

    private let defaults = UserDefaults.standard
    private let sysAudioKey = "antibleed.permission.systemAudio"

    public init() {
        if let raw = defaults.string(forKey: sysAudioKey), let s = PermissionState(rawValue: raw) { systemAudio = s }
    }

    public func refreshMicStatus() {
#if canImport(AVFoundation) && os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .denied: mic = .denied
        case .restricted: mic = .restricted
        case .notDetermined: mic = .notDetermined
        @unknown default: mic = .notDetermined
        }
#endif
    }

    @MainActor
    public func requestMic() async -> PermissionState {
#if canImport(AVFoundation) && os(macOS)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        mic = granted ? .granted : .denied
#endif
        return mic
    }

    /// Called by the pipeline after a tap-capture attempt.
    public func recordSystemAudioOutcome(granted: Bool) {
        systemAudio = granted ? .granted : .denied
        defaults.set(systemAudio.rawValue, forKey: sysAudioKey)
    }

    public func openMicrophoneSettings() {
#if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
#endif
    }

    public func openSystemAudioSettings() {
#if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
#endif
    }
}
