#if DEBUG
import AppKit

enum DebugCapture {
    static func scheduleIfNeeded() {
        guard let path = ProcessInfo.processInfo.environment["UU_CAPTURE_PATH"], !path.isEmpty else { return }
        let delay = Double(ProcessInfo.processInfo.environment["UU_CAPTURE_DELAY"] ?? "6") ?? 6
        let repeats = Int(ProcessInfo.processInfo.environment["UU_CAPTURE_REPEAT"] ?? "0") ?? 0
        for index in 0...max(0, repeats) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(index) * 5) {
                let url: URL
                if index == 0 {
                    url = URL(fileURLWithPath: path)
                } else {
                    let base = URL(fileURLWithPath: path)
                    url = base.deletingPathExtension()
                        .appendingPathExtension("\(index)")
                        .appendingPathExtension(base.pathExtension)
                }
                capture(to: url.path)
            }
        }
    }

    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }),
              let view = window.contentView else {
            print("[debug-capture] no window")
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let bounds = view.bounds
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                print("[debug-capture] wrote view \(path)")
            }
        }

        if let layer = view.layer {
            let scale = window.backingScaleFactor
            let width = Int(bounds.width * scale)
            let height = Int(bounds.height * scale)
            if let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.scaleBy(x: scale, y: scale)
                layer.render(in: context)
                if let image = context.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    let layerURL = url.deletingPathExtension().appendingPathExtension("layer.png")
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: layerURL)
                        print("[debug-capture] wrote layer \(layerURL.path)")
                    }
                }
            }
        }
    }
}
#endif
