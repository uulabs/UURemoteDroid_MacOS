import Foundation

/// Android log priority, in increasing severity.
public enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    case verbose, debug, info, warning, error, fatal

    public init?(letter: Character) {
        switch letter {
        case "V": self = .verbose
        case "D": self = .debug
        case "I": self = .info
        case "W": self = .warning
        case "E": self = .error
        case "F", "A": self = .fatal
        default: return nil
        }
    }

    public var letter: String {
        switch self {
        case .verbose: return "V"
        case .debug: return "D"
        case .info: return "I"
        case .warning: return "W"
        case .error: return "E"
        case .fatal: return "F"
        }
    }

    public var name: String {
        switch self {
        case .verbose: return "Verbose"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .fatal: return "Fatal"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One line of `adb logcat -v threadtime` output.
public struct LogcatEntry: Identifiable, Equatable, Sendable {
    public let id: Int
    /// `MM-DD HH:MM:SS.mmm`, empty for lines that are not log records.
    public let timestamp: String
    public let pid: String
    public let tid: String
    /// Nil for non-record lines such as `--------- beginning of main`.
    public let level: LogLevel?
    public let tag: String
    public let message: String

    public init(id: Int, timestamp: String, pid: String, tid: String, level: LogLevel?, tag: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.pid = pid
        self.tid = tid
        self.level = level
        self.tag = tag
        self.message = message
    }

    /// The line in threadtime layout, for copying and saving.
    public var text: String {
        guard let level else { return message }
        return "\(timestamp) \(pid) \(tid) \(level.letter) \(tag): \(message)"
    }
}

public enum LogcatParser {
    /// Parses one threadtime line:
    /// `11-16 10:21:33.123  1234  5678 I ActivityManager: Start proc …`
    public static func parse(_ line: String, id: Int) -> LogcatEntry {
        let chars = Array(line)
        var index = 0
        func skipSpaces() { while index < chars.count, chars[index] == " " { index += 1 } }
        func token() -> String {
            let start = index
            while index < chars.count, chars[index] != " " { index += 1 }
            return String(chars[start..<index])
        }
        func plain() -> LogcatEntry {
            LogcatEntry(id: id, timestamp: "", pid: "", tid: "", level: nil, tag: "", message: line)
        }

        let date = token()
        skipSpaces()
        let time = token()
        guard date.count == 5, date.dropFirst(2).first == "-",
              time.count >= 8, time.dropFirst(2).first == ":" else { return plain() }
        skipSpaces()
        let pid = token()
        skipSpaces()
        let tid = token()
        skipSpaces()
        guard !pid.isEmpty, pid.allSatisfy(\.isNumber),
              !tid.isEmpty, tid.allSatisfy(\.isNumber),
              index < chars.count, let level = LogLevel(letter: chars[index]) else { return plain() }
        index += 1
        skipSpaces()
        // The tag runs to the first ": " (tags may contain spaces and padding).
        let rest = String(chars[index...])
        let tag: String
        let message: String
        if let range = rest.range(of: ": ") {
            tag = rest[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            message = String(rest[range.upperBound...])
        } else if rest.hasSuffix(":") {
            tag = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
            message = ""
        } else {
            tag = ""
            message = rest
        }
        return LogcatEntry(
            id: id,
            timestamp: "\(date) \(time)",
            pid: pid,
            tid: tid,
            level: level,
            tag: tag,
            message: message
        )
    }
}

/// What a logcat view shows: a minimum level plus a case-insensitive search.
/// `tag:Foo`, `pid:123` and `-word` (exclude) terms can be mixed with plain
/// words; every term must match.
public struct LogcatFilter: Equatable, Sendable {
    public var minimumLevel: LogLevel
    public var search: String

    public init(minimumLevel: LogLevel = .verbose, search: String = "") {
        self.minimumLevel = minimumLevel
        self.search = search
    }

    private enum Term {
        case text(String)
        case exclude(String)
        case tag(String)
        case pid(String)
    }

    private var terms: [Term] {
        search.split(separator: " ").compactMap { raw in
            let word = raw.lowercased()
            if word.hasPrefix("tag:"), word.count > 4 { return .tag(String(word.dropFirst(4))) }
            if word.hasPrefix("pid:"), word.count > 4 { return .pid(String(word.dropFirst(4))) }
            if word.hasPrefix("-"), word.count > 1 { return .exclude(String(word.dropFirst())) }
            return .text(word)
        }
    }

    public var isEmpty: Bool { minimumLevel == .verbose && terms.isEmpty }

    /// A matcher with the search parsed once, for filtering many entries.
    public func matcher() -> (LogcatEntry) -> Bool {
        let terms = self.terms
        let minimum = minimumLevel
        return { entry in
            if let level = entry.level {
                if level < minimum { return false }
            } else if minimum > .verbose {
                return false
            }
            guard !terms.isEmpty else { return true }
            let tag = entry.tag.lowercased()
            let haystack = tag + " " + entry.message.lowercased()
            for term in terms {
                switch term {
                case .text(let word):
                    if !haystack.contains(word) { return false }
                case .exclude(let word):
                    if haystack.contains(word) { return false }
                case .tag(let word):
                    if !tag.contains(word) { return false }
                case .pid(let value):
                    if entry.pid != value { return false }
                }
            }
            return true
        }
    }
}

/// Streams `adb logcat` for one device and hands complete lines back in
/// batches. Call `stop()` to end the adb process.
public final class LogcatStream: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    /// adb runs under a small shell guard that kills it as soon as this pipe
    /// closes, so a force-quit or crash of the app never leaves adb logcat
    /// running in the background.
    private let lifeline = Pipe()
    private let lock = NSLock()
    private var partial = Data()
    private var stopped = false

    /// - Parameters:
    ///   - backlog: how many recent lines to include before following.
    ///   - onLines: called on a background queue with each batch of lines.
    ///   - onExit: called once when adb exits, with its status.
    public init(
        adb: URL,
        serial: String,
        backlog: Int = 1000,
        onLines: @escaping @Sendable ([String]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"exec 3<&0; "$0" "$@" </dev/null & c=$!; (read _ <&3; kill $c 2>/dev/null) & w=$!; wait $c; s=$?; kill $w 2>/dev/null; exit $s"#,
            adb.path,
            "-s", serial, "logcat", "-v", "threadtime", "-T", String(max(1, backlog))
        ]
        process.standardInput = lifeline
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard let self else { return }
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            let lines = self.consume(data)
            if !lines.isEmpty { onLines(lines) }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            handle.readabilityHandler = nil
            if let rest = try? handle.readToEnd(), !rest.isEmpty {
                let lines = self.consume(rest)
                if !lines.isEmpty { onLines(lines) }
            }
            try? handle.close()
            process.terminationHandler = nil
            onExit(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            process.terminationHandler = nil
            try? handle.close()
            try? pipe.fileHandleForWriting.close()
            try? lifeline.fileHandleForWriting.close()
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        try? lifeline.fileHandleForReading.close()
    }

    deinit { stop() }

    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        // Closing the lifeline makes the guard kill adb and exit.
        try? lifeline.fileHandleForWriting.close()
    }

    private func consume(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else {
            // Guard against a runaway line with no newline.
            if partial.count > 256_000 {
                let line = String(decoding: partial, as: UTF8.self)
                partial.removeAll()
                return [line]
            }
            return []
        }
        let complete = partial[partial.startIndex...lastNewline]
        partial = Data(partial[partial.index(after: lastNewline)...])
        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
    }
}
