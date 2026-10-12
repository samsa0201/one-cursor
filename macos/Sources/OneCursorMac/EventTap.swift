import CoreGraphics
import Foundation

public enum EventTapError: Error, CustomStringConvertible {
    case cannotCreate

    public var description: String {
        "cannot create the event tap; grant Accessibility (and Input Monitoring) permission in System Settings > Privacy & Security"
    }
}

/// A session-wide CoreGraphics event tap on the main run loop. The handler
/// returns true to swallow an event.
public final class EventTap {
    public typealias Handler = (CGEventType, CGEvent) -> Bool

    /// NX_SYSDEFINED: media and brightness keys arrive as these.
    public static let systemDefined = CGEventType(rawValue: 14)!

    fileprivate let handler: Handler
    fileprivate var port: CFMachPort?
    private var source: CFRunLoopSource?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start() throws {
        guard port == nil else { return }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
            Self.systemDefined,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw EventTapError.cannotCreate
        }
        self.port = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        source = nil
    }

    deinit { stop() }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS disables taps that are too slow; turn it back on.
        if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return tap.handler(type, event) ? nil : Unmanaged.passUnretained(event)
}
