import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

struct TrackpadContact {
    let identifier: Int32
    let position: CGPoint
}

enum MultitouchTrackpadMonitorError: LocalizedError {
    case frameworkUnavailable
    case symbolUnavailable(String)
    case multitouchUnavailable
    case noTrackpadFound

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return "MultitouchSupport.framework is unavailable."
        case .symbolUnavailable(let name):
            return "Missing MultitouchSupport symbol: \(name)."
        case .multitouchUnavailable:
            return "MultitouchSupport reports no available default device."
        case .noTrackpadFound:
            return "No default trackpad device was found."
        }
    }
}

final class MultitouchTrackpadMonitor: @unchecked Sendable {
    typealias ContactHandler = @Sendable ([TrackpadContact], TimeInterval) -> Void

    private let handle: UnsafeMutableRawPointer
    private let device: MTDeviceRef
    private let startDevice: MTDeviceStartFunction
    private let stopDevice: MTDeviceStopFunction
    private let releaseDevice: MTDeviceReleaseFunction
    private let isRunning: MTDeviceIsRunningFunction
    private let registerCallback: MTRegisterContactFrameCallbackFunction
    private let unregisterCallback: MTUnregisterContactFrameCallbackFunction

    private var running = false
    private(set) var diagnosticText: String

    init() throws {
        let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            throw MultitouchTrackpadMonitorError.frameworkUnavailable
        }

        self.handle = handle
        let isAvailable: MTDeviceIsAvailableFunction = try loadSymbol("MTDeviceIsAvailable", from: handle)
        let createDefaultDevice: MTDeviceCreateDefaultFunction = try loadSymbol("MTDeviceCreateDefault", from: handle)
        self.registerCallback = try loadSymbol("MTRegisterContactFrameCallback", from: handle)
        self.unregisterCallback = try loadSymbol("MTUnregisterContactFrameCallback", from: handle)
        self.startDevice = try loadSymbol("MTDeviceStart", from: handle)
        self.stopDevice = try loadSymbol("MTDeviceStop", from: handle)
        self.releaseDevice = try loadSymbol("MTDeviceRelease", from: handle)
        self.isRunning = try loadSymbol("MTDeviceIsRunning", from: handle)

        guard isAvailable() else {
            throw MultitouchTrackpadMonitorError.multitouchUnavailable
        }

        guard let device = createDefaultDevice() else {
            throw MultitouchTrackpadMonitorError.noTrackpadFound
        }

        self.device = device
        self.diagnosticText = "Default trackpad device, not started"
    }

    deinit {
        stop()
        releaseDevice(device)
        dlclose(handle)
    }

    func start(handler: @escaping ContactHandler) {
        guard !running else { return }

        contactFrameHandler = handler
        registerCallback(device, contactFrameCallback)

        let result = startDevice(device, 0)
        running = result == 0 || isRunning(device)
        diagnosticText = "Default trackpad device, start: \(result), running: \(running ? "yes" : "no")"
    }

    func stop() {
        guard running else { return }

        unregisterCallback(device, contactFrameCallback)
        _ = stopDevice(device)
        contactFrameHandler = nil
        running = false
        diagnosticText = "Default trackpad device, stopped"
    }
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTDeviceIsAvailableFunction = @convention(c) () -> Bool
private typealias MTDeviceCreateDefaultFunction = @convention(c) () -> MTDeviceRef?
private typealias MTDeviceStartFunction = @convention(c) (MTDeviceRef, Int32) -> Int32
private typealias MTDeviceStopFunction = @convention(c) (MTDeviceRef) -> Int32
private typealias MTDeviceReleaseFunction = @convention(c) (MTDeviceRef) -> Void
private typealias MTDeviceIsRunningFunction = @convention(c) (MTDeviceRef) -> Bool
private typealias MTRegisterContactFrameCallbackFunction = @convention(c) (MTDeviceRef, MTContactFrameCallback?) -> Void
private typealias MTUnregisterContactFrameCallbackFunction = @convention(c) (MTDeviceRef, MTContactFrameCallback?) -> Void
private typealias MTContactFrameCallback = @convention(c) (MTDeviceRef, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

private struct MTPoint {
    var x: Float32
    var y: Float32
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerId: Int32
    var handId: Int32
    var normalizedPosition: MTVector
    var total: Float32
    var pressure: Float32
    var angle: Float32
    var majorAxis: Float32
    var minorAxis: Float32
    var absolutePosition: MTVector
    var field14: Int32
    var field15: Int32
    var density: Float32
}

nonisolated(unsafe) private var contactFrameHandler: MultitouchTrackpadMonitor.ContactHandler?

private let contactFrameCallback: MTContactFrameCallback = { _, touches, count, timestamp, _ in
    guard let rawTouches = touches, count > 0 else {
        contactFrameHandler?([], timestamp)
        return
    }

    let typedTouches = rawTouches.bindMemory(to: MTTouch.self, capacity: Int(count))
    let contacts = (0..<Int(count)).map { index in
        let touch = typedTouches[index]
        return TrackpadContact(
            identifier: touch.identifier,
            position: CGPoint(
                x: CGFloat(touch.normalizedPosition.position.x),
                y: CGFloat(touch.normalizedPosition.position.y)
            )
        )
    }

    contactFrameHandler?(contacts, timestamp)
}

private func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) throws -> T {
    guard let symbol = dlsym(handle, name) else {
        throw MultitouchTrackpadMonitorError.symbolUnavailable(name)
    }

    return unsafeBitCast(symbol, to: T.self)
}
