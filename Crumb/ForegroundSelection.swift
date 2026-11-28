import Foundation
import CoreGraphics

/// Choose the central dish and small overlapping accessories, rather than every object in the photo.
enum ForegroundSelection {
    struct Object {
        let id: Int
        let pixels: Int
        let bounds: CGRect
    }
    static func choose(_ objects: [Object], focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> IndexSet {
        let candidates = objects.filter { $0.pixels > 0 && !$0.bounds.isEmpty }
        guard !candidates.isEmpty else { return [] }
        let containing = candidates.filter { $0.bounds.contains(focus) }
        let primary: Object
        if let object = containing.max(by: { $0.pixels < $1.pixels }) { primary = object }
        else {
            primary = candidates.max { score($0, focus: focus) < score($1, focus: focus) }!
        }
        var selected = IndexSet(integer: primary.id)
        let neighborhood = primary.bounds.insetBy(dx: -0.025, dy: -0.025)
        for object in candidates where object.id != primary.id && object.pixels <= primary.pixels * 2 / 5 {
            let overlap = object.bounds.intersection(neighborhood)
            let fraction = overlap.isNull ? 0 : overlap.width * overlap.height / (object.bounds.width * object.bounds.height)
            if fraction >= 0.35 { selected.insert(object.id) }
        }
        return selected
    }
    private static func score(_ object: Object, focus: CGPoint) -> Double {
        let dx = max(object.bounds.minX - focus.x, 0, focus.x - object.bounds.maxX)
        let dy = max(object.bounds.minY - focus.y, 0, focus.y - object.bounds.maxY)
        return Double(object.pixels) / (0.12 + 6 * (dx * dx + dy * dy))
    }
}
