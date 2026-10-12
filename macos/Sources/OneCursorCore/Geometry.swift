import Foundation

public struct Point: Equatable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { "(\(x), \(y))" }
}

/// An axis-aligned rectangle in a top-left origin coordinate space (y grows down),
/// the convention of both CoreGraphics global display coordinates and Barrier.
public struct Rect: Equatable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }

    /// Half-open containment: the last addressable pixel is `max - 1`.
    public func contains(_ p: Point) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }

    public func union(_ o: Rect) -> Rect {
        let nx = min(minX, o.minX), ny = min(minY, o.minY)
        return Rect(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }

    /// Clamps `p` into the addressable area.
    public func clamp(_ p: Point) -> Point {
        Point(x: Swift.min(Swift.max(p.x, minX), maxX - 1), y: Swift.min(Swift.max(p.y, minY), maxY - 1))
    }

    public var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }
}

/// The local screen made of one or more displays.
public struct DisplayLayout: Equatable {
    public var displays: [Rect]

    public init(_ displays: [Rect]) {
        self.displays = displays.isEmpty ? [Rect(x: 0, y: 0, width: 1920, height: 1080)] : displays
    }

    public var bounds: Rect { displays.dropFirst().reduce(displays[0]) { $0.union($1) } }

    public func display(containing p: Point) -> Rect? {
        displays.first { p.x >= $0.minX && p.x <= $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }
    }

    private func inAnyDisplay(_ p: Point) -> Bool { displays.contains { $0.contains(p) } }

    /// True when `p` is on a display edge in `direction` with no display beyond it,
    /// i.e. the cursor cannot move further that way on this machine.
    public func isAtOuterEdge(_ p: Point, _ direction: Direction) -> Bool {
        guard let d = display(containing: p) else { return false }
        switch direction {
        case .left: return p.x <= d.minX + 0.5 && !inAnyDisplay(Point(x: d.minX - 1, y: p.y))
        case .right: return p.x >= d.maxX - 1.5 && !inAnyDisplay(Point(x: d.maxX + 0.5, y: p.y))
        case .top: return p.y <= d.minY + 0.5 && !inAnyDisplay(Point(x: p.x, y: d.minY - 1))
        case .bottom: return p.y >= d.maxY - 1.5 && !inAnyDisplay(Point(x: p.x, y: d.maxY + 0.5))
        }
    }

    /// The closest point to `p` that lies on a display.
    public func nearestPoint(to p: Point) -> Point {
        var best = displays[0].clamp(p)
        var bestDist = Double.infinity
        for d in displays {
            let c = d.clamp(p)
            let dist = (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y)
            if dist < bestDist {
                best = c
                bestDist = dist
            }
        }
        return best
    }
}

extension Direction {
    /// Fraction (0...1) of `p` along the edge of `r` that faces this direction.
    func fraction(of p: Point, in r: Rect) -> Double {
        switch self {
        case .left, .right: return r.height > 1 ? min(max((p.y - r.minY) / (r.height - 1), 0), 1) : 0
        case .top, .bottom: return r.width > 1 ? min(max((p.x - r.minX) / (r.width - 1), 0), 1) : 0
        }
    }

    /// The point just inside `r` when entering it while moving in this direction,
    /// at fraction `t` along the edge.
    func entryPoint(into r: Rect, at t: Double) -> Point {
        let fx = r.minX + t * max(r.width - 1, 0)
        let fy = r.minY + t * max(r.height - 1, 0)
        switch self {
        case .right: return Point(x: r.minX + 1, y: fy.rounded())
        case .left: return Point(x: r.maxX - 2, y: fy.rounded())
        case .bottom: return Point(x: fx.rounded(), y: r.minY + 1)
        case .top: return Point(x: fx.rounded(), y: r.maxY - 2)
        }
    }
}
