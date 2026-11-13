import SwiftUI
import AppKit
import AVFoundation
import RemoteDroidCore

struct RemoteScreenView: NSViewRepresentable {
    @ObservedObject var session: ScrcpySession
    var interactive: Bool = true
    var onActivate: (() -> Void)?
    var onKeyboardFocusChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> RemoteScreenNSView {
        let view = RemoteScreenNSView()
        view.setSession(session)
        view.interactive = interactive
        view.onActivate = onActivate
        view.onKeyboardFocusChange = onKeyboardFocusChange
        view.attach(displayLayer: session.displayLayer)
        view.videoSize = session.videoSize
        return view
    }

    func updateNSView(_ nsView: RemoteScreenNSView, context: Context) {
        nsView.setSession(session)
        nsView.interactive = interactive
        nsView.onActivate = onActivate
        nsView.onKeyboardFocusChange = onKeyboardFocusChange
        nsView.attach(displayLayer: session.displayLayer)
        nsView.videoSize = session.videoSize
    }
}

final class RemoteScreenNSView: NSView {
    weak var session: ScrcpySession?
    var interactive = true
    var onActivate: (() -> Void)?
    var onKeyboardFocusChange: ((Bool) -> Void)?
    var videoSize: CGSize = .zero

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var isPointerDown = false
    private var lastPoint: (x: Int, y: Int)?
    private var displayAttached = false
    private let attachmentToken = UUID()
    private var windowObservers: [NSObjectProtocol] = []
    private var keyboardIsFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var lastLoggedBounds: CGRect = .zero

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
        #if DEBUG
        if !bounds.equalTo(lastLoggedBounds) {
            lastLoggedBounds = bounds
            print("[display-view] layout bounds=\(bounds) layerFrame=\(displayLayer?.frame ?? .zero)")
        }
        #endif
    }

    func attach(displayLayer newLayer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== newLayer else {
            newLayer.frame = bounds
            return
        }
        displayLayer?.removeFromSuperlayer()
        newLayer.frame = bounds
        layer?.addSublayer(newLayer)
        displayLayer = newLayer
    }

    func setSession(_ newSession: ScrcpySession) {
        guard session !== newSession else { return }
        if displayAttached {
            session?.displayDidDetach(token: attachmentToken)
            displayAttached = false
        }
        session = newSession
        if window != nil {
            newSession.displayWillAttach(token: attachmentToken)
            displayAttached = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if DEBUG
        print("[display-view] viewDidMoveToWindow window=\(window?.windowNumber ?? -1) bounds=\(bounds) attached=\(displayAttached)")
        #endif
        observeFullScreenChanges()
        if window != nil, !displayAttached {
            session?.displayWillAttach(token: attachmentToken)
            displayAttached = true
        } else if window == nil, displayAttached {
            session?.displayDidDetach(token: attachmentToken)
            displayAttached = false
        }
    }

    deinit {
        if displayAttached {
            session?.displayDidDetach(token: attachmentToken)
        }
        removeWindowObservers()
    }

    private func observeFullScreenChanges() {
        removeWindowObservers()
        guard let window else { return }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] notification in
                #if DEBUG
                print("[display-view] fullscreen event \(notification.name.rawValue)")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self?.refreshSurfaceAfterWindowTransition()
                }
            }
            windowObservers.append(token)
        }
    }

    private func removeWindowObservers() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
    }

    private func refreshSurfaceAfterWindowTransition() {
        guard window != nil else { return }
        lastLoggedBounds = .zero
        // Reparent the layer so the new fullscreen window gets a fresh
        // compositing surface, then ask the session for a fresh keyframe.
        if let layer = displayLayer {
            layer.removeFromSuperlayer()
        }
        layoutSubtreeIfNeeded()
        if let layer = displayLayer {
            layer.frame = bounds
            self.layer?.addSublayer(layer)
        }
        session?.refreshDisplaySurface()
        window?.makeFirstResponder(self)
        #if DEBUG
        print("[display-view] refreshed surface bounds=\(bounds)")
        #endif
    }

    override func becomeFirstResponder() -> Bool {
        keyboardIsFocused = true
        onKeyboardFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        keyboardIsFocused = false
        onKeyboardFocusChange?(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        onActivate?()
        window?.makeFirstResponder(self)
        guard let point = map(event.locationInWindow) else { return }
        isPointerDown = true
        lastPoint = point
        session?.touchDown(x: point.x, y: point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, isPointerDown, let point = map(event.locationInWindow) else { return }
        lastPoint = point
        session?.touchMove(x: point.x, y: point.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive, isPointerDown else { return }
        isPointerDown = false
        if let point = map(event.locationInWindow) ?? lastPoint {
            session?.touchUp(x: point.x, y: point.y)
        }
        lastPoint = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactive else { return }
        onActivate?()
        window?.makeFirstResponder(self)
        session?.pressBack()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard interactive else { return }
        onActivate?()
        window?.makeFirstResponder(self)
        session?.pressHome()
    }

    override func scrollWheel(with event: NSEvent) {
        guard interactive, let point = map(event.locationInWindow) else { return }
        window?.makeFirstResponder(self)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.55 : 1.0
        let horizontal = Float(event.scrollingDeltaX * scale)
        let vertical = Float(event.scrollingDeltaY * scale)
        guard abs(horizontal) > 0.01 || abs(vertical) > 0.01 else { return }
        session?.scroll(x: point.x, y: point.y, horizontal: horizontal, vertical: vertical)
    }

    override func keyDown(with event: NSEvent) {
        guard interactive, let session else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                session.paste(text)
            }
            return
        }

        if let keycode = androidKeycode(for: event) {
            let needsShortcutModifier = flags.contains(.command) || flags.contains(.control)
            let isSpecial = specialKeyCodes.contains(event.keyCode)
            if isSpecial || needsShortcutModifier {
                session.press(keycode, metaState: metaState(for: flags))
                return
            }
        }

        // Unmodified printable input goes through the text channel, which
        // preserves Unicode and avoids depending on the Android IME layout.
        if let characters = event.characters, !characters.isEmpty {
            if !flags.contains(.command), !flags.contains(.control) {
                session.sendText(characters)
            }
            return
        }

        if let keycode = androidKeycode(for: event) {
            session.press(keycode, metaState: metaState(for: flags))
        }
    }

    override func keyUp(with event: NSEvent) {
        // Keys are injected as complete down/up pairs for lowest latency.
    }

    private var specialKeyCodes: Set<UInt16> {
        [36, 76, 48, 51, 117, 53, 115, 119, 116, 121, 123, 124, 125, 126]
    }

    private func androidKeycode(for event: NSEvent) -> UInt32? {
        switch event.keyCode {
        case 36, 76: return AndroidKey.enter
        case 48: return AndroidKey.tab
        case 51: return AndroidKey.delete
        case 117: return AndroidKey.forwardDelete
        case 53: return AndroidKey.escape
        case 115: return AndroidKey.moveHome
        case 119: return AndroidKey.moveEnd
        case 116: return AndroidKey.pageUp
        case 121: return AndroidKey.pageDown
        case 123: return AndroidKey.dpadLeft
        case 124: return AndroidKey.dpadRight
        case 125: return AndroidKey.dpadDown
        case 126: return AndroidKey.dpadUp
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else {
                return nil
            }
            return AndroidKeycode.forCharacter(character)
        }
    }

    private func metaState(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var state: UInt32 = 0
        if flags.contains(.shift) { state |= AndroidMeta.shift }
        if flags.contains(.option) { state |= AndroidMeta.alt }
        if flags.contains(.control) || flags.contains(.command) { state |= AndroidMeta.control }
        return state
    }

    /// Converts an AppKit window point into the device's video coordinate
    /// system, accounting for the aspect-fit letterbox.
    private func map(_ windowPoint: NSPoint) -> (x: Int, y: Int)? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        let point = convert(windowPoint, from: nil)
        return DisplayGeometry.devicePoint(for: point, videoSize: videoSize, in: bounds)
    }
}
