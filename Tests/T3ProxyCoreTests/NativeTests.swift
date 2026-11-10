import Foundation
import Testing
@testable import T3ProxyCore

@Test func nativeMenuTitles() {
    let pools = [QuotaPool(provider: .claude, kind: .session, remaining: 41.9, accounts: 1, measured: 1, resetAt: nil),
                 QuotaPool(provider: .claude, kind: .weekly, remaining: 19.1, accounts: 1, measured: 1, resetAt: nil),
                 QuotaPool(provider: .codex, kind: .weekly, remaining: 80, accounts: 1, measured: 1, resetAt: nil)]
    #expect(NativeMenuBarMode.icon.title(pools: pools) == "")
    #expect(NativeMenuBarMode.lowest.title(pools: pools) == "19%")
    #expect(NativeMenuBarMode.providers.title(pools: pools) == "Claude 19% · Codex 80%")
    #expect(NativeMenuBarMode.lowest.title(pools: []) == "—")
    #expect(NativeMenuBarMode.providers.title(pools: []) == "Claude — · Codex —")
}

@Test func nativeShortcutPersistence() throws {
    let name = "NativeTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(NativeHotKey.load(from: defaults) == .defaultShortcut)
    let custom = NativeHotKey(keyCode: 40, modifiers: NativeHotKey.command | NativeHotKey.shift, key: "K")
    NativeHotKey.save(custom, to: defaults)
    #expect(NativeHotKey.load(from: defaults) == custom)
    NativeHotKey.save(nil, to: defaults)
    #expect(NativeHotKey.load(from: defaults) == nil)
    #expect(NativeHotKey(keyCode: 1, modifiers: 0, key: "S").isValid == false)
    defaults.set(Data("junk".utf8), forKey: NativeHotKey.defaultsKey)
    #expect(NativeHotKey.load(from: defaults) == .defaultShortcut)
}

@Test func nativeBrewParsing() throws {
    let data = Data(#"{"formulae":[{"name":"cliproxyapi","full_name":"cliproxyapi","versions":{"stable":"8.0.60"},"installed":[{"version":"8.0.55"}],"linked_keg":"8.0.55"}]}"#.utf8)
    let info = try #require(HubUpdateInstallation.parse(data))
    #expect(info.installed == "8.0.55")
    #expect(info.latest == "8.0.60")
    #expect(HubUpdateInstallation.parse(Data(#"{"formulae":[]}"#.utf8)) == nil)
    #expect(HubUpdateInstallation.parse(Data(#"{"formulae":[{"name":"other","installed":[{"version":"1"}]}]}"#.utf8)) == nil)
    #expect(HubUpdateInstallation.parse(Data("broken".utf8)) == nil)
}

@Test func nativeOutputRedaction() {
    let output = HubUpdateOutput.redact("Authorization: Bearer secretABC123\nAPI_KEY=secret12345\nuser@example.com\nhttps://user:password@example.com/x\nghp_abcdefghijklmnopqrstuvwxyz1234567890")
    for secret in ["secretABC123", "secret12345", "user@example.com", "password", "ghp_abcdefghijklmnopqrstuvwxyz1234567890"] {
        #expect(!output.contains(secret))
    }
    #expect(HubUpdateOutput.redact("Upgrading cliproxyapi 8.0.55 → 8.0.60").contains("8.0.60"))
}

@Test func nativeUsageAccountLabels() {
    let a = Account(name: "user@example.com", provider: .claude, nickname: "Work", authIndex: "index")
    let key = PlanCache.accountKey("index")
    #expect(nativeUsageAccountLabel(key, provider: .claude, accounts: [a]) == "Work")
    #expect(nativeUsageAccountLabel(key, provider: .codex, accounts: [a]) == key)
    var email = a; email.nickname = nil
    #expect(!nativeUsageAccountLabel(key, provider: .claude, accounts: [email]).contains("@"))
    #expect(nativeUsageAccountLabel("unknown", provider: .claude, accounts: []) == "unknown")
    #expect(nativeUsageAccountLabel("", provider: .claude, accounts: []) == "API key")
}

@Test func nativeMenuTitlesRejectNonFiniteQuotaAndClamp() {
    let values = [QuotaPool(provider: .claude, kind: .session, remaining: .nan, accounts: 1, measured: 1, resetAt: nil),
                  QuotaPool(provider: .codex, kind: .weekly, remaining: 101, accounts: 1, measured: 1, resetAt: nil)]
    #expect(NativeMenuBarMode.lowest.title(pools: values) == "100%")
    #expect(NativeHotKey.defaultShortcut.label == "⌃⌥⌘P")
}

@Test func nativeOutputRedactsQuotedAndURLSecrets() {
    let raw = #"{"refresh_token":"very-private-refresh","email":"example@domain.test"} https://host/path?access_token=very-private-access&ok=true sk-abcdefghijklmnop"#
    let result = HubUpdateOutput.redact(raw)
    for secret in ["very-private-refresh", "very-private-access", "example@domain.test", "sk-abcdefghijklmnop"] {
        #expect(!result.contains(secret))
    }
}

private actor FakeHubRunner: HubCommandRunning {
    enum Outcome: Sendable { case success, failure, timeout, cancellation, cancelTask }
    var commands: [[String]] = []
    let outcome: Outcome
    init(_ outcome: Outcome) { self.outcome = outcome }
    func run(_ arguments: [String], limits: HubCommandLimits, line: @escaping @Sendable (String) -> Void) async throws -> HubCommandResult {
        commands.append(arguments)
        switch outcome {
        case .success: return HubCommandResult(status: 0)
        case .failure: return HubCommandResult(status: 1)
        case .timeout: throw HubCommandError.timedOut
        case .cancellation: throw HubCommandError.cancelled
        case .cancelTask:
            withUnsafeCurrentTask { $0?.cancel() }
            return HubCommandResult(status: 0)
        }
    }
}

@Test func nativeUpdateNeverRestartsAfterFailureTimeoutOrCancel() async {
    for outcome in [FakeHubRunner.Outcome.failure, .timeout, .cancellation, .cancelTask] {
        let runner = FakeHubRunner(outcome)
        // Isolate cancellation of the fixture's owning task from the test's task.
        let failed = await Task {
            do { try await HubUpdater(runner: runner).update(line: { _ in }); return false }
            catch { return true }
        }.value
        #expect(failed)
        #expect(await runner.commands == [["upgrade", "cliproxyapi"]])
    }
    let runner = FakeHubRunner(.success)
    do { try await HubUpdater(runner: runner).update(line: { _ in }) }
    catch { Issue.record("Unexpected update failure: \(error)") }
    #expect(await runner.commands == [["upgrade", "cliproxyapi"], ["services", "restart", "cliproxyapi"]])
}

@Test func nativeUpdateExactSecretRedaction() {
    let key = "a-management-value-without-a-pattern"
    #expect(HubUpdateOutput.redact("Unexpected \(key) error", secrets: [key]) == "Unexpected [redacted] error")
}

@Test func nativeBrewValidationRejectsUntrustedFiles() throws {
    #expect(throws: HubCommandError.unsafeExecutable) { try HomebrewCommandRunner.validatedExecutable("/bin/sh") }
    // Use a non-world-writable ancestor chain; /tmp is intentionally rejected by the validator.
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3proxy-validation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let brew = root.appendingPathComponent("brew")
    try Data("fixture".utf8).write(to: brew)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
    #expect(try HomebrewCommandRunner.validatedExecutable(brew.path, root: root.path) == brew.path)
    for permissions in [0o775, 0o757] {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: brew.path)
        #expect(throws: HubCommandError.unsafeExecutable) { try HomebrewCommandRunner.validatedExecutable(brew.path, root: root.path) }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
    #expect(throws: HubCommandError.unsafeExecutable) { try HomebrewCommandRunner.validatedExecutable(brew.path, root: root.path) }
}

@Test func nativeProcessTimeoutDoesNotWaitForHeldPipe() async {
    let start = ContinuousClock.now
    do {
        _ = try await HomebrewCommandRunner().execute("/bin/sh", arguments: ["-c", "trap '' TERM; /bin/sleep 30 & wait"],
            limits: HubCommandLimits(total: 0.2, silence: 5, grace: 0.1), line: { _ in })
        Issue.record("Hung process succeeded")
    } catch { #expect(error as? HubCommandError == .timedOut) }
    #expect(start.duration(to: .now) < .seconds(3))
}

@Test func nativeProcessCancellationStopsHungCommand() async {
    let (stream, events) = AsyncStream<String>.makeStream()
    let task = Task {
        defer { events.finish() }
        return try await HomebrewCommandRunner().execute("/bin/sh", arguments: ["-c", "trap '' TERM; echo ready; /bin/sleep 30 & wait"],
            limits: HubCommandLimits(total: 10, silence: 10, grace: 0.1), line: { events.yield($0) })
    }
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == "ready")
    let start = ContinuousClock.now
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled command succeeded") }
    catch { #expect(error as? HubCommandError == .cancelled) }
    events.finish()
    #expect(start.duration(to: .now) < .seconds(3))
}

@Test func nativeProcessSilenceTimeout() async {
    do {
        _ = try await HomebrewCommandRunner().execute("/bin/sh", arguments: ["-c", "exec /bin/sleep 30"],
            limits: HubCommandLimits(total: 10, silence: 0.2, grace: 0.1), line: { _ in })
        Issue.record("Silent command succeeded")
    } catch { #expect(error as? HubCommandError == .timedOut) }
}

@Test func nativeProcessCancellationKillsTermIgnoringDescendant() async throws {
    let (stream, events) = AsyncStream<String>.makeStream()
    let task = Task {
        defer { events.finish() }
        return try await HomebrewCommandRunner().execute("/bin/sh", arguments: ["-c",
            "trap '' TERM; /bin/sh -c 'trap \"\" TERM; echo child:$$; while :; do :; done' & wait"],
            limits: HubCommandLimits(total: 10, silence: 10, grace: 0.1), line: { events.yield($0) })
    }
    var iterator = stream.makeAsyncIterator()
    let ready = try #require(await iterator.next())
    let child = try #require(ready.split(separator: ":").last.flatMap { Int32($0) })
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled process succeeded") }
    catch { #expect(error as? HubCommandError == .cancelled) }
    events.finish()
    let probe = try await HomebrewCommandRunner().execute("/bin/ps", arguments: ["-o", "stat=", "-p", String(child)],
        limits: .inspection, line: { _ in })
    let state = String(decoding: probe.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    // A killed grandchild can briefly be a zombie pending init's reap, but must not be running.
    #expect(state.isEmpty || state.hasPrefix("Z"))
}
