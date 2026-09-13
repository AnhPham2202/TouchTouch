import AppKit
import Foundation
import Observation

enum GestureBinding: String, CaseIterable, Identifiable {
    case commandOneFingerTap
    case commandTwoFingerTap
    case threeFingerDoubleTap
    case threeFingerHold
    case fourFingerDoubleTap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandOneFingerTap:
            return "Cmd + 1-Finger Tap"
        case .commandTwoFingerTap:
            return "Cmd + 2-Finger Tap"
        case .threeFingerDoubleTap:
            return "3-Finger Double Tap"
        case .threeFingerHold:
            return "3-Finger Hold (preserves selection)"
        case .fourFingerDoubleTap:
            return "4-Finger Double Tap"
        }
    }
}

@MainActor
@Observable
final class TouchTouchEngine {
    var isEnabled = true {
        didSet {
            updateRunningState()
        }
    }

    private(set) var copyBindings: Set<GestureBinding> = [.fourFingerDoubleTap]
    private(set) var pasteBindings: Set<GestureBinding> = [.threeFingerDoubleTap, .threeFingerHold]

    private(set) var statusText = "Starting..."
    private(set) var monitorText = "Trackpad monitor not started"
    private(set) var debugText = "No touch frames yet"
    private(set) var recognizerText = "No recognizer debug yet"
    private(set) var gestureText = "No gesture yet"

    private let shortcutSender = KeyboardShortcutSender()
    @ObservationIgnored private lazy var recognizer = ThreeFingerTapRecognizer { [weak self] gesture in
        DispatchQueue.main.async {
            self?.handleRecognizedGesture(gesture)
        }
    } onDebug: { [weak self] message in
        DispatchQueue.main.async {
            self?.recognizerText = message
        }
    }
    private var monitor: MultitouchTrackpadMonitor?
    private var lastDebugUpdate: TimeInterval = 0

    private static let copyBindingsKey = "TouchTouch.copyBindings"
    private static let pasteBindingsKey = "TouchTouch.pasteBindings"
    private static let legacyCopyBindingKey = "TouchTouch.copyBinding"
    private static let legacyPasteBindingKey = "TouchTouch.pasteBinding"

    init() {
        copyBindings = Self.savedBindings(
            forKey: Self.copyBindingsKey,
            legacyKey: Self.legacyCopyBindingKey,
            fallback: [.fourFingerDoubleTap]
        )
        pasteBindings = Self.savedBindings(
            forKey: Self.pasteBindingsKey,
            legacyKey: Self.legacyPasteBindingKey,
            fallback: [.threeFingerDoubleTap, .threeFingerHold]
        )
        removeConflictingPasteBindings()

        NSApplication.shared.setActivationPolicy(.accessory)
        setupMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.updateRunningState()
        }
    }

    func quit() {
        monitor?.stop()
        NSApplication.shared.terminate(nil)
    }

    func isCopyBindingEnabled(_ binding: GestureBinding) -> Bool {
        copyBindings.contains(binding)
    }

    func isPasteBindingEnabled(_ binding: GestureBinding) -> Bool {
        pasteBindings.contains(binding)
    }

    func isCopyBindingDisabled(_ binding: GestureBinding) -> Bool {
        pasteBindings.contains(binding)
    }

    func isPasteBindingDisabled(_ binding: GestureBinding) -> Bool {
        copyBindings.contains(binding)
    }

    func setCopyBinding(_ binding: GestureBinding, isEnabled: Bool) {
        if isEnabled {
            pasteBindings.remove(binding)
            copyBindings.insert(binding)
        } else {
            copyBindings.remove(binding)
        }

        saveBindings()
    }

    func setPasteBinding(_ binding: GestureBinding, isEnabled: Bool) {
        if isEnabled {
            copyBindings.remove(binding)
            pasteBindings.insert(binding)
        } else {
            pasteBindings.remove(binding)
        }

        saveBindings()
    }

    private func setupMonitor() {
        do {
            monitor = try MultitouchTrackpadMonitor()
            monitorText = monitor?.diagnosticText ?? "Trackpad monitor unavailable"
            statusText = "Enabled"
        } catch {
            monitor = nil
            statusText = error.localizedDescription
            debugText = error.localizedDescription
            isEnabled = false
        }
    }

    private func updateRunningState() {
        guard let monitor else { return }

        if isEnabled {
            if !shortcutSender.hasAccessibilityPermission {
                shortcutSender.requestAccessibilityPermission()
                statusText = "Needs Accessibility permission"
            } else {
                statusText = "Enabled"
            }

            let recognizer = recognizer
            monitor.start { [weak self] contacts, timestamp in
                recognizer.process(contacts: contacts, timestamp: timestamp)
                self?.updateDebugText(contactCount: contacts.count, timestamp: timestamp)
            }
            monitorText = monitor.diagnosticText
        } else {
            recognizer.reset()
            monitor.stop()
            monitorText = monitor.diagnosticText
            statusText = "Disabled"
            debugText = "Disabled"
        }
    }

    private func refreshPermissionStatus() {
        statusText = shortcutSender.hasAccessibilityPermission ? "Enabled" : "Needs Accessibility permission"
    }

    private nonisolated func updateDebugText(contactCount: Int, timestamp: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard timestamp - lastDebugUpdate > 0.15 else { return }

            lastDebugUpdate = timestamp
            debugText = "Last touch frame: \(contactCount) finger\(contactCount == 1 ? "" : "s")"
        }
    }

    private func handleRecognizedGesture(_ gesture: ThreeFingerTapRecognizer.Gesture) {
        handleBinding(GestureBinding(gesture))
    }

    private func handleBinding(_ binding: GestureBinding) {
        let time = Date.now.formatted(date: .omitted, time: .standard)

        if copyBindings.contains(binding) {
            gestureText = "Last gesture: \(binding.title) at \(time) -> Copy"
            // print("[TouchTouch] Send copy via \(binding.title)")
            shortcutSender.send(.copy)
        } else if pasteBindings.contains(binding) {
            gestureText = "Last gesture: \(binding.title) at \(time) -> Paste"
            // print("[TouchTouch] Send paste via \(binding.title)")
            shortcutSender.send(.paste)
        } else {
            gestureText = "Last gesture: \(binding.title) at \(time) -> Unbound"
            // print("[TouchTouch] Gesture unbound: \(binding.title)")
        }

        refreshPermissionStatus()
    }

    private func removeConflictingPasteBindings() {
        pasteBindings.subtract(copyBindings)
        saveBindings()
    }

    private func saveBindings() {
        UserDefaults.standard.set(copyBindings.map(\.rawValue), forKey: Self.copyBindingsKey)
        UserDefaults.standard.set(pasteBindings.map(\.rawValue), forKey: Self.pasteBindingsKey)
    }

    private static func savedBindings(
        forKey key: String,
        legacyKey: String,
        fallback: Set<GestureBinding>
    ) -> Set<GestureBinding> {
        if let rawValues = UserDefaults.standard.array(forKey: key) as? [String] {
            return Set(rawValues.compactMap(GestureBinding.init(rawValue:)))
        }

        if let legacyRawValue = UserDefaults.standard.string(forKey: legacyKey),
           let legacyBinding = GestureBinding(rawValue: legacyRawValue) {
            return [legacyBinding]
        }

        return fallback
    }
}

private extension GestureBinding {
    init(_ gesture: ThreeFingerTapRecognizer.Gesture) {
        switch gesture {
        case .commandOneFingerTap:
            self = .commandOneFingerTap
        case .commandTwoFingerTap:
            self = .commandTwoFingerTap
        case .threeFingerDoubleTap:
            self = .threeFingerDoubleTap
        case .threeFingerHold:
            self = .threeFingerHold
        case .fourFingerDoubleTap:
            self = .fourFingerDoubleTap
        }
    }
}
