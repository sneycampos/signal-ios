import CoreGraphics

/// One room label to place, already projected to screen points.
public struct RoomLabelInput: Equatable, Sendable {
    public var id: String
    /// Screen point of the room's label anchor.
    public var anchor: CGPoint
    /// Room area, used only to give bigger rooms priority.
    public var area: Float
    /// Size of the label with name and percentage.
    public var fullSize: CGSize
    /// Size of the percentage-only label.
    public var compactSize: CGSize

    public init(id: String, anchor: CGPoint, area: Float, fullSize: CGSize, compactSize: CGSize) {
        self.id = id
        self.anchor = anchor
        self.area = area
        self.fullSize = fullSize
        self.compactSize = compactSize
    }
}

public struct RoomLabelPlacement: Equatable, Sendable {
    public var id: String
    public var center: CGPoint
    public var compact: Bool

    public init(id: String, center: CGPoint, compact: Bool) {
        self.id = id
        self.center = center
        self.compact = compact
    }

    public func frame(in inputs: [RoomLabelInput]) -> CGRect? {
        guard let input = inputs.first(where: { $0.id == id }) else { return nil }
        let size = compact ? input.compactSize : input.fullSize
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Places room labels from room geometry only.
///
/// The probe, its tooltip and the routers are deliberately not inputs: they float above the labels,
/// so dragging them never moves a label. Bigger rooms go first (ties broken by id); a label that
/// would overlap an earlier one tries one row below, then above, then falls back to the percentage
/// alone, and is hidden if nothing fits.
public enum RoomLabelLayout {
    public static func layout(_ inputs: [RoomLabelInput], rowOffset: CGFloat = 36) -> [RoomLabelPlacement] {
        let ordered = inputs.sorted { $0.area != $1.area ? $0.area > $1.area : $0.id < $1.id }
        var occupied: [CGRect] = []
        var result: [RoomLabelPlacement] = []
        for input in ordered {
            let a = input.anchor
            let candidates = [a, CGPoint(x: a.x, y: a.y + rowOffset), CGPoint(x: a.x, y: a.y - rowOffset)]
            placing: for (compact, size) in [(false, input.fullSize), (true, input.compactSize)] {
                for center in candidates {
                    let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
                    if !occupied.contains(where: { $0.intersects(rect) }) {
                        occupied.append(rect)
                        result.append(RoomLabelPlacement(id: input.id, center: center, compact: compact))
                        break placing
                    }
                }
            }
        }
        return result
    }
}
