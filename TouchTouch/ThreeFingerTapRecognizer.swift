import ApplicationServices
import CoreGraphics
import Foundation

final class ThreeFingerTapRecognizer {
    enum Gesture {
        case commandOneFingerTap
        case commandTwoFingerTap
        case threeFingerDoubleTap(TimeInterval)
        case threeFingerHold(TimeInterval)
        case fourFingerDoubleTap(TimeInterval)
    }

    private struct CandidateTap {
        let fingerCount: Int
        let startedAt: TimeInterval
        let startCentroid: CGPoint
        var latestTime: TimeInterval
        var maxFingerCount: Int
        var commandWasDownAtStart: Bool
        var maxMovement: CGFloat = 0
        var invalidated = false
        var completed = false
    }

    private struct PendingTap {
        let endedAt: TimeInterval
        let timeout: DispatchWorkItem
    }

    private let queue = DispatchQueue(label: "TouchTouch.ThreeFingerTapRecognizer")
    private let onGesture: @Sendable (Gesture) -> Void
    private let onDebug: @Sendable (String) -> Void

    private var candidate: CandidateTap?
    private var pendingThreeFingerTap: PendingTap?
    private var pendingFourFingerTap: PendingTap?
    private var pendingContactEnd: DispatchWorkItem?
    private var lastContactCount = 0
    private var lastContactTimestamp: TimeInterval?

    private let maximumTapDuration: TimeInterval = 0.36
    private let maximumTapMovement: CGFloat = 0.10
    private let maximumCommandTwoFingerTapMovement: CGFloat = 0.20
    private let maximumFourFingerTapMovement: CGFloat = 0.15
    private let doubleTapInterval: TimeInterval = 0.75
    private let threeFingerHoldDuration: TimeInterval = 0.55
    private let contactEndSilenceInterval: TimeInterval = 0.055
    private let contactSeparationInterval: TimeInterval = 0.075
    private let fingerRampUpInterval: TimeInterval = 0.12

    init(
        onGesture: @escaping @Sendable (Gesture) -> Void,
        onDebug: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onGesture = onGesture
        self.onDebug = onDebug
    }

    func process(contacts: [TrackpadContact], timestamp: TimeInterval) {
        queue.async { [weak self] in
            self?.processOnQueue(contacts: contacts, timestamp: timestamp)
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.candidate = nil
            self?.lastContactCount = 0
            self?.lastContactTimestamp = nil
            self?.cancelPendingContactEnd()
            self?.cancelPendingThreeFingerTap(reason: "reset")
            self?.cancelPendingFourFingerTap(reason: "reset")
        }
    }

    private func processOnQueue(contacts: [TrackpadContact], timestamp: TimeInterval) {
        let contactCount = contacts.count

        if (1...4).contains(contactCount) {
            if let candidate,
               candidate.fingerCount == contactCount,
               timestamp - candidate.latestTime > contactSeparationInterval {
                cancelPendingContactEnd()
                finish(candidate: candidate, endedAt: candidate.latestTime)
                self.candidate = nil
                lastContactCount = 0
            }

            handleTapFrame(contacts: contacts, timestamp: timestamp, fingerCount: contactCount)
            scheduleContactEndFallback()
        } else if let candidate {
            cancelPendingContactEnd()
            finish(candidate: candidate, endedAt: timestamp)
            self.candidate = nil
        }

        if contactCount > 4 {
            candidate?.invalidated = true
            cancelPendingContactEnd()
            cancelPendingThreeFingerTap(reason: "more than 4 fingers")
            cancelPendingFourFingerTap(reason: "more than 4 fingers")
            debug("Rejected: \(contactCount) fingers")
        }

        lastContactCount = contactCount
        lastContactTimestamp = timestamp
    }

    private func handleTapFrame(contacts: [TrackpadContact], timestamp: TimeInterval, fingerCount: Int) {
        let centroid = Self.centroid(of: contacts)

        guard var candidate else {
            if canStartTapAfterPreviousContact(fingerCount: fingerCount, timestamp: timestamp) {
                if lastContactCount > 0 {
                    debug("Accepted ramp-up: \(lastContactCount)->\(fingerCount)")
                }

                self.candidate = CandidateTap(
                    fingerCount: fingerCount,
                    startedAt: timestamp,
                    startCentroid: centroid,
                    latestTime: timestamp,
                    maxFingerCount: fingerCount,
                    commandWasDownAtStart: Self.isCommandDown
                )
            } else {
                self.candidate = CandidateTap(
                    fingerCount: fingerCount,
                    startedAt: timestamp,
                    startCentroid: centroid,
                    latestTime: timestamp,
                    maxFingerCount: fingerCount,
                    commandWasDownAtStart: Self.isCommandDown,
                    invalidated: true
                )
                debug("Rejected start: previous contact count was \(lastContactCount)")
            }
            return
        }

        if candidate.completed {
            self.candidate = candidate
            return
        }

        candidate.latestTime = timestamp
        candidate.maxFingerCount = max(candidate.maxFingerCount, fingerCount)
        candidate.maxMovement = max(candidate.maxMovement, Self.distance(from: candidate.startCentroid, to: centroid))

        if isToleratedFingerJitter(candidate: candidate, fingerCount: fingerCount) {
            debug("Tolerated finger jitter: \(candidate.fingerCount)->\(fingerCount)")
        } else if candidate.fingerCount != fingerCount {
            candidate.invalidated = true
            cancelPendingThreeFingerTap(reason: "finger count changed")
            cancelPendingFourFingerTap(reason: "finger count changed")
            debug("Rejected: finger count changed \(candidate.fingerCount)->\(fingerCount)")
        } else if candidate.maxMovement > maximumMovement(for: candidate) {
            candidate.invalidated = true
            cancelPendingThreeFingerTap(reason: "movement too large")
            cancelPendingFourFingerTap(reason: "movement too large")
            debug("Rejected: movement \(Self.round(candidate.maxMovement)), limit \(Self.round(maximumMovement(for: candidate)))")
        } else if shouldFireThreeFingerHold(candidate: candidate, timestamp: timestamp) {
            candidate.completed = true
            cancelPendingThreeFingerTap(reason: "3-finger hold paste")
            let duration = timestamp - candidate.startedAt
            debug("3-finger hold: duration \(Self.ms(duration))ms -> paste")
            onGesture(.threeFingerHold(duration))
        } else if shouldRejectForDuration(candidate: candidate, timestamp: timestamp) {
            candidate.invalidated = true
            cancelPendingThreeFingerTap(reason: "tap duration too long")
            cancelPendingFourFingerTap(reason: "tap duration too long")
            debug("Rejected: duration \(Self.ms(timestamp - candidate.startedAt))ms")
        }

        self.candidate = candidate
    }

    private func canStartTapAfterPreviousContact(fingerCount: Int, timestamp: TimeInterval) -> Bool {
        guard lastContactCount > 0 else { return true }
        guard lastContactCount < fingerCount else { return false }
        guard let lastContactTimestamp else { return false }

        return timestamp - lastContactTimestamp <= fingerRampUpInterval
    }

    private func maximumMovement(for candidate: CandidateTap) -> CGFloat {
        if candidate.commandWasDownAtStart && candidate.maxFingerCount == 2 {
            return maximumCommandTwoFingerTapMovement
        }

        return candidate.maxFingerCount >= 4 ? maximumFourFingerTapMovement : maximumTapMovement
    }

    private func isToleratedFingerJitter(candidate: CandidateTap, fingerCount: Int) -> Bool {
        if (candidate.fingerCount == 4 && fingerCount == 3) || (candidate.fingerCount == 3 && fingerCount == 4) {
            return true
        }

        if candidate.commandWasDownAtStart &&
            ((candidate.fingerCount == 2 && fingerCount == 1) || (candidate.fingerCount == 1 && fingerCount == 2)) {
            return true
        }

        return false
    }

    private func shouldFireThreeFingerHold(candidate: CandidateTap, timestamp: TimeInterval) -> Bool {
        !candidate.completed &&
            !candidate.invalidated &&
            candidate.fingerCount == 3 &&
            candidate.maxFingerCount == 3 &&
            timestamp - candidate.startedAt >= threeFingerHoldDuration
    }

    private func shouldRejectForDuration(candidate: CandidateTap, timestamp: TimeInterval) -> Bool {
        guard !candidate.completed else { return false }

        let duration = timestamp - candidate.startedAt
        if candidate.maxFingerCount == 3 {
            return duration > threeFingerHoldDuration + contactEndSilenceInterval
        }

        return duration > maximumTapDuration
    }

    private func finish(candidate: CandidateTap, endedAt: TimeInterval) {
        let duration = max(candidate.latestTime, endedAt) - candidate.startedAt
        guard !candidate.completed else {
            debug("Completed hold ignored finish")
            return
        }

        guard !candidate.invalidated else {
            debug("Rejected finish: invalidated")
            return
        }

        guard duration <= maximumTapDuration else {
            debug("Rejected finish: duration \(Self.ms(duration))ms")
            return
        }

        let movementLimit = maximumMovement(for: candidate)
        guard candidate.maxMovement <= movementLimit else {
            debug("Rejected finish: movement \(Self.round(candidate.maxMovement)), limit \(Self.round(movementLimit))")
            return
        }

        switch candidate.maxFingerCount {
        case 1:
            finishCommandTap(candidate: candidate, fingerCount: 1, duration: duration)
        case 2:
            finishCommandTap(candidate: candidate, fingerCount: 2, duration: duration)
        case 3:
            finishThreeFingerTap(endedAt: endedAt)
        case 4:
            finishFourFingerTap(endedAt: endedAt, duration: duration, movement: candidate.maxMovement)
        default:
            break
        }
    }

    private func finishCommandTap(candidate: CandidateTap, fingerCount: Int, duration: TimeInterval) {
        guard candidate.commandWasDownAtStart else {
            debug("Ignored \(fingerCount)-finger tap: Cmd was not down at start")
            return
        }

        debug("Cmd + \(fingerCount)-finger tap: duration \(Self.ms(duration))ms")
        if fingerCount == 1 {
            onGesture(.commandOneFingerTap)
        } else {
            onGesture(.commandTwoFingerTap)
        }
    }

    private func finishThreeFingerTap(endedAt: TimeInterval) {
        if let pendingThreeFingerTap {
            let gap = endedAt - pendingThreeFingerTap.endedAt
            cancelPendingThreeFingerTap(reason: "double tap recognized")
            cancelPendingFourFingerTap(reason: "3-finger double tap")
            debug("3-finger double tap: gap \(Self.ms(gap))ms")
            onGesture(.threeFingerDoubleTap(gap))
        } else {
            debug("3-finger first tap: waiting \(Self.ms(doubleTapInterval))ms")
            scheduleThreeFingerTapTimeout(endedAt: endedAt)
        }
    }

    private func finishFourFingerTap(endedAt: TimeInterval, duration: TimeInterval, movement: CGFloat) {
        cancelPendingThreeFingerTap(reason: "4-finger tap")

        if let pendingFourFingerTap {
            let gap = endedAt - pendingFourFingerTap.endedAt
            cancelPendingFourFingerTap(reason: "double tap recognized")
            debug("4-finger double tap: gap \(Self.ms(gap))ms, duration \(Self.ms(duration))ms, movement \(Self.round(movement)) -> copy")
            onGesture(.fourFingerDoubleTap(gap))
        } else {
            debug("4-finger first tap: waiting \(Self.ms(doubleTapInterval))ms")
            scheduleFourFingerTapTimeout(endedAt: endedAt)
        }
    }

    private func scheduleContactEndFallback() {
        cancelPendingContactEnd()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let candidate else { return }

            finish(candidate: candidate, endedAt: candidate.latestTime)
            self.candidate = nil
            lastContactCount = 0
            lastContactTimestamp = nil
        }

        pendingContactEnd = workItem
        queue.asyncAfter(deadline: .now() + contactEndSilenceInterval, execute: workItem)
    }

    private func cancelPendingContactEnd() {
        pendingContactEnd?.cancel()
        pendingContactEnd = nil
    }

    private func scheduleThreeFingerTapTimeout(endedAt: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.debug("3-finger first tap expired")
            self?.pendingThreeFingerTap = nil
        }

        pendingThreeFingerTap = PendingTap(endedAt: endedAt, timeout: workItem)
        queue.asyncAfter(deadline: .now() + doubleTapInterval, execute: workItem)
    }

    private func cancelPendingThreeFingerTap(reason: String) {
        if pendingThreeFingerTap != nil, reason != "double tap recognized" {
            debug("Pending 3-finger tap canceled: \(reason)")
        }

        pendingThreeFingerTap?.timeout.cancel()
        pendingThreeFingerTap = nil
    }

    private func scheduleFourFingerTapTimeout(endedAt: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.debug("4-finger first tap expired")
            self?.pendingFourFingerTap = nil
        }

        pendingFourFingerTap = PendingTap(endedAt: endedAt, timeout: workItem)
        queue.asyncAfter(deadline: .now() + doubleTapInterval, execute: workItem)
    }

    private func cancelPendingFourFingerTap(reason: String) {
        if pendingFourFingerTap != nil, reason != "double tap recognized" {
            debug("Pending 4-finger tap canceled: \(reason)")
        }

        pendingFourFingerTap?.timeout.cancel()
        pendingFourFingerTap = nil
    }

    private func debug(_ message: String) {
        // print("[TouchTouch] \(message)")
        onDebug(message)
    }

    private static var isCommandDown: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(.maskCommand)
    }

    private static func centroid(of contacts: [TrackpadContact]) -> CGPoint {
        let total = contacts.reduce(CGPoint.zero) { partialResult, contact in
            CGPoint(
                x: partialResult.x + contact.position.x,
                y: partialResult.y + contact.position.y
            )
        }

        return CGPoint(x: total.x / CGFloat(contacts.count), y: total.y / CGFloat(contacts.count))
    }

    private static func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let deltaX = lhs.x - rhs.x
        let deltaY = lhs.y - rhs.y
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }

    private static func ms(_ interval: TimeInterval) -> Int {
        Int((interval * 1_000).rounded())
    }

    private static func round(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}
