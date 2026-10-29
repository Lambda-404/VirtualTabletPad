import CoreGraphics
import Foundation

/// Protocol abstracting CGEvent posting to enable deterministic testing
/// without posting synthetic events into the macOS window server.
public protocol EventPosting: Sendable {
    func post(_ event: CGEvent)
    func post(_ event: CGEvent, tap: CGEventTapLocation)
}

extension EventPosting {
    public func post(_ event: CGEvent) {
        post(event, tap: .cghidEventTap)
    }
}

/// The default event poster that posts events directly to the specified CoreGraphics event tap.
public struct DefaultEventPoster: EventPosting {
    public init() {}

    public func post(_ event: CGEvent, tap: CGEventTapLocation) {
        event.post(tap: tap)
    }
}

/// A thread-safe recording mock event poster for testing event injection sequences.
public final class MockEventPoster: EventPosting, @unchecked Sendable {
    public struct PostedEvent: @unchecked Sendable {
        public let type: CGEventType
        public let location: CGPoint
        public let flags: CGEventFlags
        public let tap: CGEventTapLocation
        public let subtype: Int64
        public let pressure: Double
        public let tiltX: Double
        public let tiltY: Double
        public let rotation: Double
        public let rawEvent: CGEvent

        public init(event: CGEvent, tap: CGEventTapLocation) {
            self.type = event.type
            self.location = event.location
            self.flags = event.flags
            self.tap = tap
            self.subtype = event.getIntegerValueField(.mouseEventSubtype)
            self.pressure = event.getDoubleValueField(.mouseEventPressure)
            self.tiltX = event.getDoubleValueField(.tabletEventTiltX)
            self.tiltY = event.getDoubleValueField(.tabletEventTiltY)
            self.rotation = event.getDoubleValueField(.tabletEventRotation)
            self.rawEvent = event
        }
    }

    private let lock = NSLock()
    private var _events: [PostedEvent] = []

    public var events: [PostedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _events.count
    }

    public init() {}

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        _events.removeAll()
    }

    public func post(_ event: CGEvent, tap: CGEventTapLocation) {
        let record = PostedEvent(event: event, tap: tap)
        lock.lock()
        defer { lock.unlock() }
        _events.append(record)
    }
}
