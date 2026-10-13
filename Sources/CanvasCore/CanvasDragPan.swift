import CoreGraphics

/// Panning the board by dragging with the middle mouse button, over empty board or any tile (the
/// Figma and Miro convention). A press becomes a pan only once the pointer moves `threshold`
/// screen points, so a middle click that stays put still reaches what is under it: a terminal's
/// paste.
public struct CanvasDragPan: Sendable {
    /// Screen points the pointer moves before a press becomes a pan.
    public static let threshold: CGFloat = 3

    public private(set) var panning = false
    private let start: CGPoint
    private var last: CGPoint

    /// A press at `point`, in window coordinates (y up).
    public init(at point: CGPoint) {
        start = point
        last = point
    }

    /// The pointer moved to `point`: how far to pan, in screen points as the content moves
    /// (positive y: down, as `CanvasWheel.Action.pan`), or nil while still under the threshold.
    public mutating func move(to point: CGPoint) -> CGSize? {
        if !panning {
            guard hypot(point.x - start.x, point.y - start.y) >= Self.threshold else { return nil }
            panning = true
        }
        defer { last = point }
        return CGSize(width: point.x - last.x, height: last.y - point.y)
    }
}
