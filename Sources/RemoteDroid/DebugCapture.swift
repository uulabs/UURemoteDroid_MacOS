#if DEBUG
import AppKit
import RemoteDroidCore

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

    /// The video layer does not render into a view snapshot, so for README
    /// screenshots each mirror is filled with an `adb screencap` of its device.
    private static func fillScreens(in root: NSView, rep: NSBitmapImageRep) {
        guard let adb = ADBClient.resolveADB(),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        for screen in screenViews(in: root) {
            guard let session = screen.session, session.videoSize.width > 0 else { continue }
            let process = Process()
            process.executableURL = adb
            process.arguments = ["-s", session.device.serial, "exec-out", "screencap", "-p"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let image = NSImage(data: data) else { continue }
            let fit = DisplayGeometry.aspectFitRect(videoSize: session.videoSize, in: screen.bounds)
            var rect = screen.convert(fit, to: root)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            image.draw(in: rect)
            print("[debug-capture] filled \(session.device.serial) at \(rect)")
        }
    }

    private static func screenViews(in view: NSView) -> [RemoteScreenNSView] {
        var found: [RemoteScreenNSView] = []
        if let screen = view as? RemoteScreenNSView, screen.window != nil, !screen.isHiddenOrHasHiddenAncestor {
            found.append(screen)
        }
        for subview in view.subviews { found += screenViews(in: subview) }
        return found
    }

    private static func capture(to path: String) {
        let wanted = ProcessInfo.processInfo.environment["UU_CAPTURE_WINDOW"]
        guard let window = NSApp.windows.first(where: {
                  $0.contentView != nil && (wanted == nil || $0.title.hasPrefix(wanted!))
              }),
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
            if ProcessInfo.processInfo.environment["UU_CAPTURE_SCREENCAP"] == "1" {
                fillScreens(in: view, rep: rep)
            }
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
