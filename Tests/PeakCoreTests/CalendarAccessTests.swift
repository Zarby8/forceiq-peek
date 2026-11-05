import Foundation
import XCTest

/// GOAT EventKit snapshot auth (Chris 11.05.2026): Peek's 5090 line said "calendar access is denied" because
/// Calendars.snapshot() only fetched on .fullAccess. Legacy .authorized must also fetch. A real denial still
/// writes denied. Source-scan only — EventKit is not available in PeakCoreTests and must not run on Linux.
/// Sample names only; this file never embeds a real client title.
final class CalendarAccessTests: XCTestCase {
    var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func calendarsBlock() throws -> String {
        let app = try String(contentsOf: repoRoot.appendingPathComponent("app/CommandBox.swift"), encoding: .utf8)
        let start = try XCTUnwrap(app.range(of: "enum Calendars {"))
        let end = try XCTUnwrap(app.range(of: "// ───────────────────────────── Vision OCR"))
        return String(app[start.lowerBound..<end.lowerBound])
    }

    func authActions(_ src: String) throws -> [String: String] {
        let fn = try XCTUnwrap(src.range(of: "static func authAction"))
        let snap = try XCTUnwrap(src.range(of: "static func snapshot()"))
        let body = String(src[fn.lowerBound..<snap.lowerBound])
        let re = try NSRegularExpression(pattern: #"case \.(\w+):\s*return \.(\w+)"#)
        var out: [String: String] = [:]
        let ns = body as NSString
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    /// Same outcomes as Calendars.snapshot() for a status with no calendars listed and no successful prompt.
    func snapshotAccess(_ status: String, auth: [String: String], calendars: Int = 0, requestOK: Bool = false, headless: Bool = false) -> String {
        switch auth[status] {
        case "fetch": return "granted"
        case "restricted": return "restricted"
        case "request":
            if calendars > 0 { return "granted" }
            if !headless && requestOK { return "granted" }
            return "denied"
        default: return "missing"
        }
    }

    func testLegacyAuthorizedAndFullAccessBothProduceAGrantedSnapshot() throws {
        let src = try calendarsBlock()
        let auth = try authActions(src)
        XCTAssertEqual(auth["authorized"], "fetch", "legacy kTCCServiceCalendar .authorized is a real grant")
        XCTAssertEqual(auth["fullAccess"], "fetch")
        XCTAssertEqual(snapshotAccess("authorized", auth: auth), "granted")
        XCTAssertEqual(snapshotAccess("fullAccess", auth: auth), "granted")
        XCTAssertTrue(src.contains("case .fetch: fetch()"))
        XCTAssertTrue(src.contains("write(\"granted\""))
        XCTAssertFalse(src.contains("rawValue == 2"), "the old default recorded a real grant as denied/restricted")
    }

    func testDeniedStaysDeniedWhenFullAccessIsRefused() throws {
        let src = try calendarsBlock()
        let auth = try authActions(src)
        XCTAssertEqual(auth["denied"], "request")
        XCTAssertEqual(auth["notDetermined"], "request")
        XCTAssertEqual(auth["writeOnly"], "request")
        XCTAssertEqual(auth["restricted"], "restricted")
        XCTAssertTrue(src.contains("if ok { fetch() } else { write(\"denied\", [], []) }"))
        XCTAssertTrue(src.contains("else { write(\"denied\", [], []) }"))
        XCTAssertTrue(src.contains("case .restricted: write(\"restricted\", [], [])"))
        XCTAssertTrue(src.contains("!HEADLESS && !requestedFullAccess"), "headless --eventkit-only must not prompt")
        XCTAssertEqual(snapshotAccess("denied", auth: auth), "denied")
        XCTAssertEqual(snapshotAccess("denied", auth: auth, requestOK: false, headless: true), "denied")
        XCTAssertEqual(snapshotAccess("denied", auth: auth, calendars: 2), "granted")
        XCTAssertEqual(snapshotAccess("notDetermined", auth: auth, requestOK: true), "granted")
    }

    func testFreshnessWordingIsStillTheAccessWord() throws {
        let ops = try String(contentsOf: repoRoot.appendingPathComponent("engine/ops.py"), encoding: .utf8)
        XCTAssertTrue(ops.contains("calendar access is {d.get('access') or 'not granted'}"))
        XCTAssertTrue(ops.contains("if d.get(\"access\") != \"granted\""))
    }
}
