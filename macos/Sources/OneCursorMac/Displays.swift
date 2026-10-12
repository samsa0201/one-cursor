import CoreGraphics
import OneCursorCore

public enum MacDisplays {
    /// All active displays in global coordinates (top-left origin, points).
    public static func layout() -> DisplayLayout {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return DisplayLayout([]) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return DisplayLayout([]) }
        var rects: [Rect] = []
        for id in ids.prefix(Int(count)) {
            let b = CGDisplayBounds(id)
            let r = Rect(x: Double(b.origin.x), y: Double(b.origin.y), width: Double(b.width), height: Double(b.height))
            // Mirrored displays report identical bounds; keep one.
            if !rects.contains(r) { rects.append(r) }
        }
        return DisplayLayout(rects)
    }

    /// Bounds of the main display (the one with the menu bar).
    public static func mainBounds() -> Rect {
        let b = CGDisplayBounds(CGMainDisplayID())
        return Rect(x: Double(b.origin.x), y: Double(b.origin.y), width: Double(b.width), height: Double(b.height))
    }
}
