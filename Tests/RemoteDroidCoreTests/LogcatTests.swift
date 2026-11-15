import XCTest
@testable import RemoteDroidCore

final class LogcatTests: XCTestCase {
    func testParsesThreadtimeLine() {
        let entry = LogcatParser.parse(
            "11-16 10:21:33.123  1234  5678 I ActivityManager: Start proc 4321:com.example/u0a12",
            id: 7
        )
        XCTAssertEqual(entry.id, 7)
        XCTAssertEqual(entry.timestamp, "11-16 10:21:33.123")
        XCTAssertEqual(entry.pid, "1234")
        XCTAssertEqual(entry.tid, "5678")
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.tag, "ActivityManager")
        XCTAssertEqual(entry.message, "Start proc 4321:com.example/u0a12")
    }

    func testParsesPaddedTagAndColonsInMessage() {
        let entry = LogcatParser.parse("11-16 10:21:33.123   99   100 E chatty  : uid=1000 a: b", id: 1)
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.tag, "chatty")
        XCTAssertEqual(entry.message, "uid=1000 a: b")
    }

    func testTagWithSpacesAndEmptyMessage() {
        let entry = LogcatParser.parse("01-02 03:04:05.678  1  2 W Some Tag:", id: 1)
        XCTAssertEqual(entry.level, .warning)
        XCTAssertEqual(entry.tag, "Some Tag")
        XCTAssertEqual(entry.message, "")
    }

    func testNonRecordLinesKeepTheirText() {
        let entry = LogcatParser.parse("--------- beginning of main", id: 1)
        XCTAssertNil(entry.level)
        XCTAssertEqual(entry.message, "--------- beginning of main")
        XCTAssertEqual(entry.text, "--------- beginning of main")
    }

    func testFatalAndAssertMapToFatal() {
        XCTAssertEqual(LogcatParser.parse("11-16 10:21:33.123 1 2 F libc: abort", id: 1).level, .fatal)
        XCTAssertEqual(LogcatParser.parse("11-16 10:21:33.123 1 2 A DEBUG: x", id: 1).level, .fatal)
    }

    func testFilterLevelSearchTagPidAndExclude() {
        let lines = [
            "11-16 10:00:00.000 100 100 D Net: connected wifi",
            "11-16 10:00:00.000 100 101 W Net: slow wifi",
            "11-16 10:00:00.000 200 200 E Camera: open failed",
            "--------- beginning of crash"
        ]
        let entries = lines.enumerated().map { LogcatParser.parse($1, id: $0) }
        func ids(_ filter: LogcatFilter) -> [Int] {
            let match = filter.matcher()
            return entries.filter(match).map(\.id)
        }
        XCTAssertEqual(ids(LogcatFilter()), [0, 1, 2, 3])
        XCTAssertEqual(ids(LogcatFilter(minimumLevel: .warning)), [1, 2])
        XCTAssertEqual(ids(LogcatFilter(search: "WIFI")), [0, 1])
        XCTAssertEqual(ids(LogcatFilter(search: "wifi -slow")), [0])
        XCTAssertEqual(ids(LogcatFilter(search: "tag:cam")), [2])
        XCTAssertEqual(ids(LogcatFilter(search: "pid:100")), [0, 1])
        XCTAssertEqual(ids(LogcatFilter(search: "net failed")), [])
    }
}
