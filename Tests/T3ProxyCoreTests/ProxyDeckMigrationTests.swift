import Foundation
import Testing
import SQLite3
@testable import T3ProxyCore

struct ProxyDeckMigrationTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func sql(_ url: URL, _ statement: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK)
    }
    @Test func activitySignalsAndOwnListener() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage.sqlite").path
        let now = Date(timeIntervalSince1970: 2000000000)
        #expect(ProxyDeckDetector(path: path, loaded: { false }, listening: { false }, now: { now }).refresh() == .absent)
        #expect(ProxyDeckDetector(path: path, loaded: { true }, listening: { false }, now: { now }).refresh() == .active)
        #expect(ProxyDeckDetector(path: path, loaded: { false }, listening: { true }, now: { now }).refresh() == .active)
        let own = ProxyDeckDetector(path: path, loaded: { false }, listening: { true }, ownsPort: { true }, now: { now })
        #expect(own.refresh() == .absent)
        try Data().write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-901)], ofItemAtPath: path)
        #expect(ProxyDeckDetector.fileState(path: path, now: now) == .retired)
        let detector = ProxyDeckDetector(path: path, loaded: { false }, listening: { false }, now: { now })
        #expect(detector.refresh() == .retired)
        try Data().write(to: URL(fileURLWithPath: path + "-wal"))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-899)], ofItemAtPath: path + "-wal")
        #expect(detector.refresh() == .active)
    }
    @Test func retiredFilesDoNotBlockRecorderButOverridesStillDo() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage.sqlite").path
        try Data().write(to: URL(fileURLWithPath: path))
        #expect(!UsageRecorder.otherRecorderPresent(fileManager: .default, proxyDeckPath: path, overridePath: nil, state: .retired))
        #expect(UsageRecorder.otherRecorderPresent(fileManager: .default, proxyDeckPath: path, overridePath: nil, state: .active))
        #expect(UsageRecorder.otherRecorderPresent(fileManager: .default, proxyDeckPath: path, overridePath: "/other", state: .retired))
        #expect(!UsageRecorder.otherRecorderPresent(fileManager: .default, proxyDeckPath: path, overridePath: UsageRecorder.defaultDatabaseURL.path, state: .absent))
    }
    @Test func retirementCommandsUseOnlyInjectedRunner() {
        let retirement = ProxyDeckRetirement(uid: 502, home: "/fixture", runner: { _ in 0 }, exists: { _ in true })
        #expect(retirement.retire().commands.map(\.arguments) == [["bootout", "gui/502/dev.proxy-deck"], ["disable", "gui/502/dev.proxy-deck"]])
        #expect(retirement.restore().commands.map(\.arguments) == [["enable", "gui/502/dev.proxy-deck"], ["bootstrap", "gui/502", "/fixture/Library/LaunchAgents/dev.proxy-deck.plist"]])
        let missing = ProxyDeckRetirement(uid: 502, home: "/fixture", runner: { _ in 0 }, exists: { _ in false }).restore()
        #expect(missing.plistMissing && !missing.succeeded && missing.commands.count == 1)
        #expect(!ProxyDeckRetirement(runner: { _ in 5 }).retire().succeeded)
    }
    @Test func historyImportPreservesRowsIdempotentlyWithoutTouchingSource() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.sqlite"), dest = dir.appendingPathComponent("own/usage.sqlite")
        try sql(source, UsageStore.schema + "INSERT INTO requests VALUES ('first',1000,'claude','test','123','oauth',1,2,3,4,5,6,7,0,8); INSERT INTO requests VALUES ('second',2000,'codex','test',NULL,'oauth',11,12,13,14,15,16,17,1,18);")
        let before = try Data(contentsOf: source)
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let result = try ProxyDeckImport.importHistory(from: source, into: dest)
        #expect(result.sourceRows == 2 && result.insertedRows == 2 && result.skippedRows == 0)
        let second = try ProxyDeckImport.importHistory(from: source, into: dest)
        #expect(second.sourceRows == 2 && second.insertedRows == 0 && second.skippedRows == 2)
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == attrs[.modificationDate] as? Date)
        #expect(!FileManager.default.fileExists(atPath: source.path + "-shm"))
        var db: OpaquePointer?; #expect(sqlite3_open_v2(dest.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT cache_read,cache_creation,total,latency_ms FROM requests WHERE id='second'", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect((0..<4).map { sqlite3_column_int64(statement, Int32($0)) } == [15,16,17,18])
        #expect(throws: (any Error).self) { try ProxyDeckImport.importHistory(from: source, into: source) }
    }
    @Test func walSnapshotIncludesUncheckpointedRowsWithoutSourceWrites() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.sqlite"), dest = dir.appendingPathComponent("own/usage.sqlite")
        var db: OpaquePointer?; #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" + UsageStore.schema + "INSERT INTO requests VALUES ('wal',1000,'claude','test',NULL,'oauth',1,2,3,4,5,6,7,0,8);", nil, nil, nil) == SQLITE_OK)
        let before = try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal"))
        #expect(try ProxyDeckImport.importHistory(from: source, into: dest).insertedRows == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal")) == before)
    }
    @Test func plansImportPreservesFingerprintsPermissionsAndNewerOwnEntry() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("plans.json"), dest = dir.appendingPathComponent("own/plans.json")
        let now = Date().timeIntervalSince1970 * 1000
        let value: [String: Any] = [PlanCache.accountKey("a"): ["plan": "team", "org": "Work", "orgId": "0123456789abcdef", "at": now], "not-a-key": ["plan": "pro", "at": now]]
        let before = try JSONSerialization.data(withJSONObject: value)
        try before.write(to: source)
        #expect(try ProxyDeckImport.importPlans(from: source, into: dest) == 1)
        let p = try #require(PlanCache.load(path: dest.path)[PlanCache.accountKey("a")])
        #expect(p.plan == "team" && p.org == "Work" && p.freshOrgID() == "0123456789abcdef")
        #expect((try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: source) == before)
        #expect(try ProxyDeckImport.importPlans(from: source, into: dest) == 1)
        #expect(PlanCache.load(path: dest.path)[PlanCache.accountKey("a")] == p)
    }
    @Test func localLoginDecodesOnlyMatchingIdentity() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude.json")
        try Data(#"{"secret":"ignored","oauthAccount":{"emailAddress":" user@example.test ","organizationUuid":" ABCD-1234 ","accessToken":"ignored"}}"#.utf8).write(to: file)
        let login = try #require(T3LocalLogin.read(file: file))
        #expect(login.email == "user@example.test")
        #expect(login.orgID == PlanCache.orgFingerprint("abcd-1234"))
        #expect(PlanCache.orgFingerprint("not a uuid") == nil)
    }
}

extension ProxyDeckMigrationTests {
    @Test func importRollsBackWholeTransactionOnSourceReadFailure() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.sqlite"), dest = dir.appendingPathComponent("own/usage.sqlite")
        try sql(source, UsageStore.schema + "INSERT INTO requests VALUES ('first',1,'claude','test',NULL,'oauth',1,2,3,4,5,6,7,0,8); INSERT INTO requests VALUES ('second',2,'claude','test',NULL,'oauth',1,2,3,4,5,6,7,0,8); ALTER TABLE requests RENAME TO source_rows; CREATE VIEW requests AS SELECT id,ts,provider,model,account_key,auth_type,input,output,reasoning,cached,cache_read,cache_creation,total,failed,CASE WHEN id='second' THEN json_extract('invalid-json','$') ELSE latency_ms END AS latency_ms FROM source_rows;")
        #expect(throws: (any Error).self) { try ProxyDeckImport.importHistory(from: source, into: dest) }
        var db: OpaquePointer?; #expect(sqlite3_open_v2(dest.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM requests", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
    }
    @Test func ownPlanEntriesWinWithFallbackForMissingAccounts() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let own = dir.appendingPathComponent("own.json"), fallback = dir.appendingPathComponent("fallback.json")
        let a = PlanCache.accountKey("a"), b = PlanCache.accountKey("b")
        try JSONSerialization.data(withJSONObject: [a: ["plan": "pro"], b: ["plan": "team"]]).write(to: fallback)
        try JSONSerialization.data(withJSONObject: [a: ["plan": "max 20x"]]).write(to: own)
        let loaded = PlanCache.load(ownPath: own.path, fallbackPath: fallback.path)
        #expect(loaded[a]?.plan == "max 20x" && loaded[b]?.plan == "team")
    }
}

@Suite struct ProxyDeckPortClaimTests {
    /// The shim must never race Proxy Deck for 127.0.0.1:8318: not before the first probe, not while its agent is loaded.
    @Test func claimsThePortOnlyAfterAProbeShowsTheAgentUnloaded() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pd-\(UUID())/usage.sqlite").path
        let loaded = ProxyDeckDetector(path: missing, loaded: { true }, listening: { false })
        #expect(!loaded.mayClaimPort)            // unknown counts as loaded
        #expect(loaded.refresh() == .active)
        #expect(!loaded.mayClaimPort)
        let gone = ProxyDeckDetector(path: missing, loaded: { false }, listening: { false })
        #expect(!gone.mayClaimPort)
        _ = gone.refresh()
        #expect(gone.mayClaimPort)
    }
}

@Suite struct ProxyDeckProbeOrderTests {
    /// A probe that saw "agent unloaded" before Restore must not publish after Restore's invalidation.
    @Test func probeStartedBeforeInvalidationCannotReopenThePort() {
        final class Gate: @unchecked Sendable { let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0) }
        let gate = Gate()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pd-\(UUID())/usage.sqlite").path
        let d = ProxyDeckDetector(path: missing, loaded: { gate.started.signal(); gate.proceed.wait(); return false }, listening: { false })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = d.refresh(); done.signal() }
        gate.started.wait()           // the probe has read "unloaded" and is about to publish
        d.invalidate()                // Restore happened meanwhile
        gate.proceed.signal()
        done.wait()
        #expect(!d.mayClaimPort)      // stale result ignored
    }

    @Test func profileFingerprintIsParsedAndRecorded() throws {
        let profile = #"{"organization":{"uuid":"6f1c2d3e-aaaa-bbbb-cccc-0123456789ab","organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"},"account":{}}"#
        let info = try LiveQuotaParser.plan(Data(profile.utf8), provider: .claude)
        #expect(info.plan == "max 20x" && info.orgID == PlanCache.orgFingerprint("6f1c2d3e-aaaa-bbbb-cccc-0123456789ab"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plans-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var fresh = info; fresh.observedAt = Date()
        PlanCache.record(key: "0123456789ab", fresh, at: url)
        let back = PlanCache.load(path: url.path)["0123456789ab"]
        #expect(back?.plan == "max 20x" && back?.freshOrgID() == info.orgID)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("6f1c2d3e"))   // only the fingerprint, never the uuid
    }
}
