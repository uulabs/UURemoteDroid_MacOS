import Foundation
import CoreGraphics

public enum DisplayGeometry {
    /// The rect occupied by an aspect-fit video inside a view. AppKit view
    /// coordinates are used (origin bottom-left).
    public static func aspectFitRect(videoSize: CGSize, in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let videoAspect = videoSize.width / videoSize.height
        let viewAspect = bounds.width / bounds.height
        if viewAspect > videoAspect {
            let width = bounds.height * videoAspect
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspect
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
    }

    /// Maps an AppKit view point to the device's video pixels, accounting for
    /// letterboxing. Y is flipped because Android's input coordinates are
    /// top-left origin while AppKit's are bottom-left.
    public static func devicePoint(
        for viewPoint: CGPoint,
        videoSize: CGSize,
        in bounds: CGRect
    ) -> (x: Int, y: Int)? {
        let rect = aspectFitRect(videoSize: videoSize, in: bounds)
        guard rect != .zero, rect.contains(viewPoint) else { return nil }
        let normalizedX = (viewPoint.x - rect.minX) / rect.width
        let normalizedY = 1 - (viewPoint.y - rect.minY) / rect.height
        let x = min(Int(videoSize.width) - 1, max(0, Int(normalizedX * videoSize.width)))
        let y = min(Int(videoSize.height) - 1, max(0, Int(normalizedY * videoSize.height)))
        return (x, y)
    }
}
