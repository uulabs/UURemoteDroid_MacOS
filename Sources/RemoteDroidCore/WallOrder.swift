import Foundation

/// Pure ordering helper for the selectable device wall.
public enum WallOrder {
    /// Moves `serial` into the slot currently occupied by `target`.
    ///
    /// Dropping a device onto another tile places it where that tile was in the
    /// left-to-right order, shifting the intervening devices.
    public static func moving(_ order: [String], serial: String, toSlotOf target: String) -> [String] {
        guard serial != target,
              let from = order.firstIndex(of: serial),
              let to = order.firstIndex(of: target) else {
            return order
        }
        var result = order
        result.remove(at: from)
        result.insert(serial, at: min(to, result.count))
        return result
    }
}
