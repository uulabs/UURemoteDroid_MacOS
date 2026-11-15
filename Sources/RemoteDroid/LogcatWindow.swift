import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RemoteDroidCore

// MARK: - Window management

/// One logcat window per device. Closing the window stops its adb process.
@MainActor
final class LogcatWindows: NSObject, NSWindowDelegate {
    static let shared = LogcatWindows()
    private var windows: [String: (window: NSWindow, model: LogcatModel)] = [:]

    func open(serial: String, deviceName: String, adb: URL) {
        if let existing = windows[serial] {
            existing.model.restartIfStopped()
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = LogcatModel(serial: serial, deviceName: deviceName, adb: adb)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Logcat · \(deviceName)"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.background)
        window.minSize = NSSize(width: 640, height: 320)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LogcatView(model: model))
        window.delegate = self
        window.setFrameAutosaveName("Logcat")
        if windows.isEmpty { window.center() } else {
            window.setFrameTopLeftPoint(NSPoint(
                x: window.frame.minX + 28 * CGFloat(windows.count),
                y: window.frame.maxY - 28 * CGFloat(windows.count)
            ))
        }
        windows[serial] = (window, model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let serial = windows.first(where: { $0.value.window === window })?.key else { return }
        windows[serial]?.model.stop()
        windows[serial] = nil
    }

    #if DEBUG
    func debugSetSearch(serial: String, _ search: String) {
        windows[serial]?.model.filter.search = search
    }
    #endif

    func stopAll() {
        windows.values.forEach { $0.model.stop() }
    }
}

// MARK: - Model

@MainActor
final class LogcatModel: ObservableObject {
    enum Status: Equatable {
        case starting
        case streaming
        case stopped(String)
    }

    static let maxEntries = 50_000

    let serial: String
    let deviceName: String
    private let adb: URL

    /// Every captured line, oldest first, capped at `maxEntries`.
    private(set) var entries: [LogcatEntry] = []
    /// The lines that pass the filter, shown in the table.
    @Published private(set) var visible: [LogcatEntry] = []
    /// Bumped whenever `visible` is rebuilt rather than appended to.
    @Published private(set) var resetToken = 0
    @Published private(set) var status: Status = .starting
    @Published var filter = LogcatFilter() {
        didSet { if filter != oldValue { rebuildVisible() } }
    }
    @Published var paused = false {
        didSet { if !paused { flush() } }
    }
    @Published var following = true

    private var stream: LogcatStream?
    private var nextID = 0
    private var timer: Timer?
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pending: [String] = []

    init(serial: String, deviceName: String, adb: URL) {
        self.serial = serial
        self.deviceName = deviceName
        self.adb = adb
    }

    var lineCount: Int { entries.count }

    func start() {
        stream?.stop()
        status = .starting
        do {
            let lock = pendingLock
            stream = try LogcatStream(
                adb: adb,
                serial: serial,
                backlog: 2000,
                onLines: { [weak self] lines in
                    guard let self else { return }
                    lock.lock()
                    self.pending.append(contentsOf: lines)
                    lock.unlock()
                },
                onExit: { [weak self] code in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.flush()
                        if case .stopped = self.status { return }
                        self.status = .stopped(code == 0 || code == 15
                            ? "Logcat ended"
                            : "Device disconnected or adb stopped (exit \(code))")
                    }
                }
            )
            status = .streaming
        } catch {
            status = .stopped("Could not start adb: \(error.localizedDescription)")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flush() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        status = .stopped("Stopped")
        stream?.stop()
        stream = nil
    }

    func restartIfStopped() {
        if case .stopped = status { start() }
    }

    func clear() {
        entries.removeAll()
        rebuildVisible()
    }

    private func flush() {
        guard !paused else { return }
        pendingLock.lock()
        let lines = pending
        pending.removeAll(keepingCapacity: true)
        pendingLock.unlock()
        guard !lines.isEmpty else { return }

        var added: [LogcatEntry] = []
        added.reserveCapacity(lines.count)
        for line in lines {
            added.append(LogcatParser.parse(line, id: nextID))
            nextID += 1
        }
        entries.append(contentsOf: added)
        if entries.count > Self.maxEntries {
            // Trim in chunks so the table is not rebuilt for every batch.
            entries.removeFirst(entries.count - Self.maxEntries + 5_000)
            rebuildVisible()
            return
        }
        let match = filter.matcher()
        let shown = added.filter(match)
        if !shown.isEmpty { visible.append(contentsOf: shown) }
    }

    private func rebuildVisible() {
        visible = filter.isEmpty ? entries : entries.filter(filter.matcher())
        resetToken += 1
    }

    func text(for rows: [LogcatEntry]) -> String {
        rows.map(\.text).joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "logcat-\(deviceName.replacingOccurrences(of: " ", with: "-"))-\(stamp).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text(for: visible).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - View

struct LogcatView: View {
    @ObservedObject var model: LogcatModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ZStack(alignment: .bottomTrailing) {
                LogcatTable(model: model)
                if !model.following && !model.visible.isEmpty {
                    Button {
                        model.following = true
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.to.line")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Theme.accent))
                            .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            footer
        }
        .background(Theme.background)
        .onAppear { searchFocused = true }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                TextField("Search   tag:Name   pid:123   -exclude", text: $model.filter.search)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text)
                    .focused($searchFocused)
                if !model.filter.search.isEmpty {
                    Button {
                        model.filter.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            )

            Picker("Level", selection: $model.filter.minimumLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text("\(level.name) and above").tag(level)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Button {
                model.paused.toggle()
            } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    .frame(width: 16)
            }
            .help(model.paused ? "Resume" : "Pause (lines keep being captured)")

            Button {
                model.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear the window (the device's log is not touched)")

            Button {
                model.save()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save the visible lines as a text file")
        }
        .padding(.leading, 84) // clear the traffic-light buttons
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            if case .stopped = model.status {
                Button("Reconnect") { model.start() }
                    .controlSize(.small)
            }
            Spacer()
            Text(countText)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var statusColor: Color {
        switch model.status {
        case .starting: return Theme.warning
        case .streaming: return model.paused ? Theme.warning : Theme.success
        case .stopped: return Theme.danger
        }
    }

    private var statusText: String {
        switch model.status {
        case .starting: return "Connecting to \(model.deviceName)…"
        case .streaming: return model.paused ? "Paused · still capturing" : "Streaming from \(model.deviceName)"
        case .stopped(let reason): return reason
        }
    }

    private var countText: String {
        let shown = model.visible.count
        let total = model.lineCount
        return shown == total ? "\(total) lines" : "\(shown) of \(total) lines"
    }
}

// MARK: - Table

private struct LogcatTable: NSViewRepresentable {
    @ObservedObject var model: LogcatModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LogTableView()
        table.headerView = nil
        table.backgroundColor = NSColor(Theme.background)
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 18
        table.allowsMultipleSelection = true
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.copyText = { [weak coordinator = context.coordinator] in coordinator?.selectedText() ?? "" }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.background)
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        context.coordinator.table = table
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scroll
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scroll
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: LogcatModel
        weak var table: NSTableView?
        private var rows: [LogcatEntry] = []
        private var resetToken = -1
        private var wasFollowing = true

        init(model: LogcatModel) {
            self.model = model
        }

        func update() {
            guard let table else { return }
            let next = model.visible
            if resetToken != model.resetToken || next.count < rows.count
                || (rows.first?.id != next.first?.id && !rows.isEmpty) {
                resetToken = model.resetToken
                rows = next
                table.reloadData()
            } else if next.count > rows.count {
                let range = rows.count..<next.count
                rows = next
                table.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
            }
            if model.following, !rows.isEmpty {
                table.scrollRowToVisible(rows.count - 1)
            }
            wasFollowing = model.following
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("logLine")
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = id
                field.lineBreakMode = .byTruncatingTail
                field.maximumNumberOfLines = 1
                field.cell?.truncatesLastVisibleLine = true
                // Truncate long lines instead of squeezing their letters.
                field.allowsDefaultTighteningForTruncation = false
            }
            field.attributedStringValue = Self.render(rows[row])
            field.toolTip = rows[row].message.count > 120 ? rows[row].message : nil
            return field
        }

        func selectedText() -> String {
            guard let table else { return "" }
            return table.selectedRowIndexes
                .filter { $0 < rows.count }
                .map { rows[$0].text }
                .joined(separator: "\n")
        }

        /// Scrolling up stops following; scrolling back to the bottom resumes.
        @objc func didLiveScroll(_ note: Notification) {
            guard let scroll = note.object as? NSScrollView else { return }
            if !isAtBottom(scroll), model.following { model.following = false }
        }

        @objc func didEndLiveScroll(_ note: Notification) {
            guard let scroll = note.object as? NSScrollView else { return }
            if isAtBottom(scroll), !model.following { model.following = true }
        }

        private func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return true }
            let visible = scroll.contentView.documentVisibleRect
            return visible.maxY >= document.bounds.maxY - 24
        }

        private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.tighteningFactorForTruncation = 0
            return style
        }()
        private static let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        private static let faint = NSColor(Theme.textFaint)
        private static let muted = NSColor(Theme.textMuted)
        private static let text = NSColor(Theme.text)

        private static func color(for level: LogLevel) -> NSColor {
            switch level {
            case .verbose: return muted
            case .debug: return NSColor(Theme.blue)
            case .info: return NSColor(Theme.success)
            case .warning: return NSColor(Theme.warning)
            case .error, .fatal: return NSColor(Theme.danger)
            }
        }

        static func render(_ entry: LogcatEntry) -> NSAttributedString {
            let result = NSMutableAttributedString()
            func add(_ string: String, _ color: NSColor, _ font: NSFont? = nil) {
                result.append(NSAttributedString(string: string, attributes: [
                    .font: font ?? Self.font, .foregroundColor: color, .paragraphStyle: paragraph
                ]))
            }
            guard let level = entry.level else {
                add("  " + entry.message, faint)
                return result
            }
            let levelColor = color(for: level)
            add("  " + entry.timestamp.dropFirst(6) + " ", faint)
            add(entry.pid.leftPadded(6) + " " + entry.tid.leftPadded(6) + " ", faint)
            add(" " + level.letter + " ", levelColor, bold)
            add(" " + entry.tag + ": ", levelColor)
            add(entry.message.replacingOccurrences(of: "\t", with: "    "),
                level >= .warning ? levelColor : text)
            return result
        }
    }
}

/// A table that copies the selected log lines with ⌘C.
private final class LogTableView: NSTableView {
    var copyText: (() -> String)?

    @objc func copy(_ sender: Any?) {
        let text = copyText?() ?? ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
