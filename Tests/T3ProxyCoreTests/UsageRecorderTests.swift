import Foundation
import SQLite3
import Testing
@testable import T3ProxyCore

private final class RecorderStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: @Sendable (URLRequest) throws -> (Int, String) = { _ in (200, "[]") }
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        do {
            let (code, body) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct UsageRecorderTests {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("recorder-" + UUID().uuidString).appendingPathComponent("usage.sqlite") }
    private func recorder(_ url: URL) -> UsageRecorder {
        UsageRecorder(databaseURL: url, client: ManagementClient(protocolClasses: [RecorderStub.self]), otherRecorder: { false })
    }
    @Test func followsTheMonitorsCurrentClientAfterAPortChange() async {
        RecorderStub.requests = []
        RecorderStub.handler = { r in
            r.url?.path.hasSuffix("/config") == true ? (200, #"{"observability":{"usage":{"usage-statistics-enabled":true}}}"#) : (200, "[]")
        }
        defer { RecorderStub.handler = { _ in (200, "[]") } }
        let recorder = UsageRecorder(databaseURL: location(), client: ManagementClient(endpoint: ProxyEndpoint(port: 8317), protocolClasses: [RecorderStub.self]),
                                     otherRecorder: { false })
        await recorder.setEnabled(true)
        _ = await recorder.tick(key: "test", client: ManagementClient(endpoint: ProxyEndpoint(port: 9123), protocolClasses: [RecorderStub.self]))
        #expect(!RecorderStub.requests.isEmpty)
        #expect(RecorderStub.requests.allSatisfy { $0.url?.host == "127.0.0.1" && $0.url?.port == 9123 })
    }
    @Test func defaultOffSendsNothing() async {
        RecorderStub.requests = []
        let recorder = recorder(location())
        #expect(await recorder.tick(key: "test") == .off)
        #expect(RecorderStub.requests.isEmpty)
    }
}

private final class RecorderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_794_312_000) // 2026-11-10 noon UTC
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval = 31) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
private let recorderConfig = #"{"observability":{"usage":{"usage-statistics-enabled":true}}}"#
private let recorderRecord = #"{"request_id":"req-1","timestamp":"2026-11-10T10:00:00Z","provider":"CLAUDE","model":"claude-sonnet-4","auth_index":"abc","auth_type":"oauth","tokens":{"input_tokens":100,"output_tokens":20,"reasoning_tokens":3,"cached_tokens":4,"total_tokens":123},"failed":true,"latency_ms":125,"api_key":"secret-api-token","source":"private-account@example.com","endpoint":"https://private.example/secret"}"#

private func recorderSQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw URLError(.cannotOpenFile) }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw URLError(.cannotWriteToFile) }
}
private func recorderRows(_ url: URL, _ sql: String) throws -> [[String?]] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw URLError(.cannotOpenFile) }
    defer { sqlite3_close(db) }
    var s: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw URLError(.cannotParseResponse) }
    defer { sqlite3_finalize(s) }
    var rows: [[String?]] = []
    while sqlite3_step(s) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(s)).map { i in sqlite3_column_text(s, i).map { String(cString: $0) } })
    }
    return rows
}

extension UsageRecorderTests {
    private func configured(_ url: URL, clock: RecorderClock = .init(), other: @escaping @Sendable () -> Bool = { false }) -> UsageRecorder {
        RecorderStub.requests = []
        return UsageRecorder(databaseURL: url, client: ManagementClient(protocolClasses: [RecorderStub.self]), otherRecorder: other, now: { clock.now() })
    }
    @Test func claudeCacheWritesComeFromTheTotalsRemainder() async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The queue has no cache-write field: 1,000 total - 10 in - 40 out - 900 read = 50 written. Codex input already
        // includes its cache reads, so its remainder is never a write.
        let claude = #"{"request_id":"w-1","timestamp":"2026-11-10T10:00:00Z","provider":"claude","model":"claude-opus-5-5","auth_type":"oauth","tokens":{"input_tokens":10,"output_tokens":40,"reasoning_tokens":0,"cached_tokens":900,"total_tokens":1000},"failed":false,"latency_ms":1}"#
        let codex = #"{"request_id":"w-2","timestamp":"2026-11-10T10:00:00Z","provider":"codex","model":"gpt-6.1-sol","auth_type":"oauth","tokens":{"input_tokens":1000,"output_tokens":40,"reasoning_tokens":0,"cached_tokens":900,"total_tokens":1040},"failed":false,"latency_ms":1}"#
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (200, "[" + claude + "," + codex + "]") }
        let recorder = configured(url, clock: clock)
        await recorder.setEnabled(true)
        _ = await recorder.tick(key: "fake")
        #expect(try recorderRows(url, "SELECT id,cache_creation FROM requests ORDER BY id") == [["w-1", "50"], ["w-2", "0"]])
    }
    @Test func mapsSchemaAndExistingReaderAndKeepsSecretsOut() async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (200, "[" + recorderRecord + "]") }
        let recorder = configured(url, clock: clock)
        await recorder.setEnabled(true)
        #expect(await recorder.tick(key: "fake") == .recording(lastAt: Account.parseDate("2026-11-10T10:00:00Z"), total: 1))
        clock.advance()
        _ = await recorder.tick(key: "fake") // repeated id is ignored
        #expect(try recorderRows(url, "SELECT id,provider,account_key,input,output,reasoning,cached,cache_read,cache_creation,total,failed,latency_ms FROM requests") == [["req-1", "claude", "ba7816bf8f01", "100", "20", "3", "4", "4", "0", "123", "1", "125"]])
        let source = SQLiteUsageSource(path: url.path), now = clock.now()
        #expect(try source.rangeDetail(days: 1, now: now).totals.total == 123)
        let account = try source.accountSummary(provider: .claude, accountKey: "ba7816bf8f01", windowStart: nil, now: now)
        #expect(account.today.total == 123 && account.last30.input == 100 && account.last30.failed == 1)
        let series = try source.series(start: now.addingTimeInterval(-86400), width: 86400, count: 1)
        #expect(series.byProvider[.claude]?.first?.total == 123)
        let schema = try recorderRows(url, "SELECT sql FROM sqlite_master").description
        #expect(!schema.contains("api_key") && !schema.contains("source") && !schema.contains("endpoint"))
        for file in try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            for secret in ["secret-api-token", "private-account@example.com", "private.example/secret", "https://"] {
                #expect(data.range(of: Data(secret.utf8)) == nil)
            }
        }
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try recorderRows(url, "PRAGMA journal_mode") == [["wal"]])
        let queue = RecorderStub.requests.filter { $0.url!.path.hasSuffix("usage-queue") }
        #expect(queue.count == 2)
        #expect(queue.allSatisfy { $0.url!.host == "127.0.0.1" && $0.url!.query == "count=200" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fake" })
    }

    @Test func validatesAndHashesCanonicalRecordWithoutIdentifiers() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let valid = #"{"timestamp":"2026-11-10T10:00:00Z","provider":"Gemini","model":"g","tokens":{"total_tokens":5},"request_id":"unsafe/@example.com"}"#
        let reordered = #"{"request_id":"unsafe/@example.com","tokens":{"total_tokens":5},"model":"g","provider":"Gemini","timestamp":"2026-11-10T10:00:00Z"}"#
        let invalid = [
            valid.replacingOccurrences(of: ":5", with: ":-5"),
            valid.replacingOccurrences(of: ":5", with: ":1e99"),
            valid.replacingOccurrences(of: ":5", with: ":true"),
            valid.replacingOccurrences(of: "2026-11-10", with: "2099-11-10"),
            valid.replacingOccurrences(of: "2026-11-10T10:00:00Z", with: "not-a-date"),
            #"{"tokens":{}}"#,
        ]
        let records = ([valid, reordered] + invalid).joined(separator: ",")
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (200, "[" + records + "]") }
        let recorder = configured(url)
        await recorder.setEnabled(true); _ = await recorder.tick(key: "fake")
        let rows = try recorderRows(url, "SELECT id,provider,model,account_key,input,total FROM requests")
        #expect(rows.count == 1)
        #expect(rows.first?[0]?.count == 64)
        #expect(rows.first?[1] == "gemini" && rows.first?[3] == nil && rows.first?[4] == "0" && rows.first?[5] == "5")
    }

    @Test func failedTransactionRetainsWholeBatchAndRetriesBeforeNextPop() async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            // Preflight succeeded, but disk becomes unwritable just as the destructive response arrives.
            try recorderSQL(url, "CREATE TRIGGER fail_write BEFORE INSERT ON requests WHEN NEW.id = 'req-2' BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END")
            return (200, "[" + recorderRecord + "," + recorderRecord.replacingOccurrences(of: "req-1", with: "req-2") + "]")
        }
        let recorder = configured(url, clock: clock)
        await recorder.setEnabled(true)
        if case .failed = await recorder.tick(key: "fake") {} else { Issue.record("Write failure was not reported") }
        #expect(try recorderRows(url, "SELECT id FROM requests").isEmpty) // first insert rolled back too
        clock.advance(120)
        if case .failed = await recorder.tick(key: "fake") {} else { Issue.record("Retry should still fail") }
        #expect(RecorderStub.requests.filter { $0.url!.path.hasSuffix("usage-queue") }.count == 1)
        try recorderSQL(url, "DROP TRIGGER fail_write")
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            #expect((try? recorderRows(url, "SELECT id FROM requests"))?.count == 2) // committed BEFORE another pop
            return (200, "[]")
        }
        #expect(await recorder.tick(key: "fake") == .recording(lastAt: Account.parseDate("2026-11-10T10:00:00Z"), total: 2))
        #expect(try recorderRows(url, "SELECT id FROM requests").count == 2)
    }

    @Test func disabledStillRecoversPendingRecordsLocally() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            try recorderSQL(url, "CREATE TRIGGER fail_write BEFORE INSERT ON requests BEGIN SELECT RAISE(ABORT, 'full'); END")
            return (200, "[" + recorderRecord + "]")
        }
        let recorder = configured(url)
        await recorder.setEnabled(true); _ = await recorder.tick(key: "fake")
        await recorder.setEnabled(false)
        let calls = RecorderStub.requests.count
        try recorderSQL(url, "DROP TRIGGER fail_write")
        #expect(await recorder.tick(key: "") == .off)
        #expect(RecorderStub.requests.count == calls)
        #expect(try recorderRows(url, "SELECT id FROM requests").count == 1)
    }

    @Test func competitorFileAndDifferentOverrideBlockWithoutRequests() async throws {
        let url = location(), competitor = location()
        defer { try? FileManager.default.removeItem(at: competitor.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: competitor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: competitor)
        #expect(UsageRecorder.otherRecorderPresent(fileManager: .default, proxyDeckPath: competitor.path, overridePath: nil))
        #expect(UsageRecorder.otherRecorderPresent(fileManager: .default, proxyDeckPath: "/nonexistent", overridePath: "/different.sqlite"))
        #expect(!UsageRecorder.otherRecorderPresent(fileManager: .default, proxyDeckPath: "/nonexistent", overridePath: UsageRecorder.defaultDatabaseURL.path))
        let recorder = configured(url, other: { FileManager.default.fileExists(atPath: competitor.path) })
        await recorder.setEnabled(true)
        #expect(await recorder.tick(key: "fake") == .blockedByOtherRecorder)
        #expect(RecorderStub.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [401, 403, 404, 503, 0]) func reportsErrorsAndBacksOff(code: Int) async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            if code == 0 { throw URLError(.notConnectedToInternet) }
            return (code, "[]")
        }
        let recorder = configured(url, clock: clock)
        await recorder.setEnabled(true)
        let first = await recorder.tick(key: "fake")
        switch code {
        case 401, 403: #expect(first == .keyRejected)
        case 404: #expect(first == .unsupported)
        case 0: #expect(first == .waitingForHub)
        default: if case .failed = first {} else { Issue.record("Expected failure") }
        }
        let count = RecorderStub.requests.count
        #expect(await recorder.tick(key: "fake") == first)
        #expect(RecorderStub.requests.count == count)
        if code == 401 || code == 403 {
            clock.advance(3600)
            #expect(await recorder.tick(key: "fake") == .keyRejected)
            #expect(RecorderStub.requests.count == count) // rejected key never resent
        }
    }

    @Test func statisticsMustBeExplicitlyEnabled() async {
        for body in [#"{"observability":{"usage":{"usage-statistics-enabled":false}}}"#, "{}"] {
            let url = location()
            RecorderStub.handler = { _ in (200, body) }
            let recorder = configured(url)
            await recorder.setEnabled(true)
            #expect(await recorder.tick(key: "fake") == .statisticsDisabled)
            #expect(RecorderStub.requests.count == 1)
            #expect(RecorderStub.requests.allSatisfy { !$0.url!.path.hasSuffix("usage-queue") })
        }
    }

    @Test func fullBatchesDrainWithBoundedTickAndPruning() async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let batch = "[" + Array(repeating: recorderRecord, count: 200).joined(separator: ",") + "]"
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (200, batch) }
        let recorder = configured(url, clock: clock)
        await recorder.setEnabled(true); _ = await recorder.tick(key: "fake")
        #expect(RecorderStub.requests.filter { $0.url!.path.hasSuffix("usage-queue") }.count == 10)
        #expect(try recorderRows(url, "SELECT id FROM requests").count == 1)
        try recorderSQL(url, "UPDATE requests SET ts=1")
        clock.advance()
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (200, "[]") }
        #expect(await recorder.tick(key: "fake") == .recording(lastAt: Account.parseDate("2026-11-10T10:00:00Z"), total: 0))
        #expect(try recorderRows(url, "SELECT id FROM requests").isEmpty)
    }
}

extension UsageRecorderTests {
    @Test func unwritableStorageAndSymlinksPreventPop() async throws {
        let root = location().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let link = root.appendingPathComponent("usage.sqlite")
        let destination = root.appendingPathComponent("must-not-create.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        for url in [blocker.appendingPathComponent("usage.sqlite"), link] {
            RecorderStub.handler = { _ in (200, recorderConfig) }
            let recorder = configured(url)
            await recorder.setEnabled(true)
            if case .failed = await recorder.tick(key: "fake") {} else { Issue.record("Storage preflight should fail") }
            #expect(!RecorderStub.requests.contains { $0.url!.path.hasSuffix("usage-queue") })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func stringsAreBoundedAndMissingFieldsAreTolerated() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let records = [
            "{\"timestamp\":\"2026-11-10T10:00:00Z\",\"model\":\"" + String(repeating: "m", count: 201) + "\",\"provider\":\"email@example.com\",\"auth_type\":\"token@example.com\"}",
            #"{"timestamp":"2026-11-10T10:00:01Z","model":"normal-model","tokens":null,"auth_index":123}"#,
        ].joined(separator: ",")
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (200, "[" + records + "]") }
        let recorder = configured(url)
        await recorder.setEnabled(true); _ = await recorder.tick(key: "fake")
        let rows = try recorderRows(url, "SELECT model,provider,auth_type,account_key,total FROM requests ORDER BY ts")
        #expect(rows == [["unknown", "unknown", "unknown", nil, "0"], ["normal-model", "unknown", "unknown", nil, "0"]])
    }

    @Test func refusalRecheckedBetweenBatchesAndSharedGateRejectsOtherClients() async throws {
        let url = location(), competitor = url.deletingLastPathComponent().appendingPathComponent("competitor.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            try Data().write(to: competitor)
            return (200, "[" + Array(repeating: recorderRecord, count: 200).joined(separator: ",") + "]")
        }
        let recorder = configured(url, other: { FileManager.default.fileExists(atPath: competitor.path) })
        await recorder.setEnabled(true)
        #expect(await recorder.tick(key: "fake") == .blockedByOtherRecorder)
        #expect(RecorderStub.requests.filter { $0.url!.path.hasSuffix("usage-queue") }.count == 1)
        #expect(try recorderRows(url, "SELECT id FROM requests").count == 1)
        try FileManager.default.removeItem(at: competitor)
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (401, "[]") }
        let client = ManagementClient(protocolClasses: [RecorderStub.self])
        let second = UsageRecorder(databaseURL: url, client: client, otherRecorder: { false }, now: { RecorderClock().now() })
        await second.setEnabled(true)
        #expect(await second.tick(key: "fake") == .keyRejected)
        #expect(!client.gate.permits("fake"))
        let calls = RecorderStub.requests.count
        await #expect(throws: ManagementError.locked) { try await client.credentials(key: "fake") }
        #expect(RecorderStub.requests.count == calls)
    }
}

extension UsageRecorderTests {
    /// A batch popped but not yet written outlives the process: it is spooled, and a NEW recorder (after a restart)
    /// writes it before any further pop.
    @Test func failedBatchIsSpooledAndRecoveredAfterRestart() async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            try recorderSQL(url, "CREATE TRIGGER IF NOT EXISTS fail_write BEFORE INSERT ON requests BEGIN SELECT RAISE(ABORT, 'disk'); END")
            return (200, "[" + recorderRecord + "]")
        }
        let first = configured(url, clock: clock)
        await first.setEnabled(true)
        if case .failed = await first.tick(key: "fake") {} else { Issue.record("Write failure was not reported") }
        let spool = url.deletingLastPathComponent().appendingPathComponent("usage-pending.json")
        let spooled = try Data(contentsOf: spool)
        #expect((try FileManager.default.attributesOfItem(atPath: spool.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for secret in ["secret-api-token", "private-account@example.com", "private.example"] { #expect(spooled.range(of: Data(secret.utf8)) == nil) }
        // "Restart": a fresh recorder, storage healthy again, the hub has nothing new.
        try recorderSQL(url, "DROP TRIGGER fail_write")
        RecorderStub.handler = { r in r.url!.path.hasSuffix("config") ? (200, recorderConfig) : (200, "[]") }
        let second = configured(url, clock: clock)
        _ = await second.tick(key: "")   // even disabled: local recovery first, no request
        #expect(try recorderRows(url, "SELECT id FROM requests") == [["req-1"]])
        #expect(!FileManager.default.fileExists(atPath: spool.path))
        #expect(RecorderStub.requests.isEmpty)
    }

    /// Quit while a pop is in flight: shutdown waits for that batch, saves it, and nothing is popped afterwards.
    @Test func shutdownWaitsForTheInFlightBatchAndStopsPopping() async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            Thread.sleep(forTimeInterval: 0.2)
            return (200, "[" + recorderRecord + "]")
        }
        let recorder = configured(url, clock: clock)
        await recorder.setEnabled(true)
        let tick = Task { await recorder.tick(key: "fake") }
        try await Task.sleep(for: .milliseconds(80))
        await recorder.shutdown()
        #expect(try recorderRows(url, "SELECT id FROM requests") == [["req-1"]])
        _ = await tick.value
        let pops = RecorderStub.requests.filter { $0.url!.path.hasSuffix("usage-queue") }.count
        clock.advance(120)
        #expect(await recorder.tick(key: "fake") == .off)
        #expect(RecorderStub.requests.filter { $0.url!.path.hasSuffix("usage-queue") }.count == pops)
    }

    /// A port change during a tick: the batch already received is saved, and the old hub is never popped again.
    @Test func retargetDuringATickStopsPoppingTheOldHub() async throws {
        let url = location(), clock = RecorderClock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Full batches would normally keep the loop popping.
        let full = "[" + (0..<200).map { recorderRecord.replacingOccurrences(of: "req-1", with: "req-\($0)") }.joined(separator: ",") + "]"
        RecorderStub.handler = { r in
            if r.url!.path.hasSuffix("config") { return (200, recorderConfig) }
            Thread.sleep(forTimeInterval: 0.15)
            return (200, full)
        }
        let recorder = configured(url, clock: clock)
        await recorder.setEnabled(true)
        let tick = Task { await recorder.tick(key: "fake") }
        try await Task.sleep(for: .milliseconds(60))
        await recorder.retarget(ManagementClient(endpoint: ProxyEndpoint(port: 9123), protocolClasses: [RecorderStub.self]))
        _ = await tick.value
        let oldPops = RecorderStub.requests.filter { $0.url!.path.hasSuffix("usage-queue") && $0.url!.port != 9123 }
        #expect(oldPops.count == 1)
        #expect(try recorderRows(url, "SELECT count(*) FROM requests") == [["200"]])
    }
}
