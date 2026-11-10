import Foundation

public struct HubUpdateInstallation: Sendable, Equatable {
    public var installed: String
    public var latest: String?
    public static func parse(_ data: Data) -> Self? {
        struct Response: Decodable {
            struct Formula: Decodable {
                struct Version: Decodable { var version: String }
                struct Versions: Decodable { var stable: String? }
                var name: String
                var installed: [Version]
                var linked_keg: String?
                var versions: Versions?
            }
            var formulae: [Formula]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let formula = response.formulae.first(where: { $0.name == "cliproxyapi" }),
              let installed = formula.installed.first(where: { $0.version == formula.linked_keg }) ?? formula.installed.last,
              !installed.version.isEmpty else { return nil }
        return Self(installed: installed.version, latest: formula.versions?.stable)
    }
}

public enum HubUpdateOutput {
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var value = LogRedactor.redact(text, secrets: secrets)
        for pattern in [#"https?://[^\s/@]+:[^\s/@]+@"#, #"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b"#,
                        #"(?i)\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY)\s*=\s*[^\s]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return value.emailHidden
    }
}

public struct HubCommandResult: Sendable {
    public var status: Int32
    public var data: Data
    public init(status: Int32, data: Data = Data()) { self.status = status; self.data = data }
}

public enum HubCommandError: Error, LocalizedError, Equatable {
    case cancelled, timedOut, unsafeExecutable, launch(Int32), failed(Int32)
    public var errorDescription: String? {
        switch self {
        case .cancelled: "Update cancelled; service was not restarted."
        case .timedOut: "Homebrew timed out; service was not restarted."
        case .unsafeExecutable: "Homebrew refused: executable must be a trusted file under /opt/homebrew with safe ownership and permissions."
        case .launch(let code): "Homebrew could not be started (error \(code))."
        case .failed(let code): "Homebrew command failed (exit \(code)); no further commands were run."
        }
    }
}

public struct HubCommandLimits: Sendable {
    public var total: TimeInterval
    public var silence: TimeInterval
    public var grace: TimeInterval
    public init(total: TimeInterval, silence: TimeInterval, grace: TimeInterval = 2) {
        self.total = total; self.silence = silence; self.grace = grace
    }
    public static let inspection = Self(total: 60, silence: 60)
    public static let upgrade = Self(total: 900, silence: 300)
}

public protocol HubCommandRunning: Sendable {
    func run(_ arguments: [String], limits: HubCommandLimits,
             line: @escaping @Sendable (String) -> Void) async throws -> HubCommandResult
}

/// Sequences mutations across an injected runner. Cancellation is checked between every command,
/// including after a runner returns successfully while its owning task has been cancelled.
public struct HubUpdater: Sendable {
    public let runner: any HubCommandRunning
    public init(runner: any HubCommandRunning) { self.runner = runner }
    public func installation() async throws -> HubUpdateInstallation? {
        try Task.checkCancellation()
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/cliproxyapi").resolvingSymlinksInPath().path
        guard executable.hasPrefix("/opt/homebrew/Cellar/cliproxyapi/") else { return nil }
        let response = try await runner.run(["info", "--json=v2", "cliproxyapi"], limits: .inspection, line: { _ in })
        try Task.checkCancellation()
        return response.status == 0 ? HubUpdateInstallation.parse(response.data) : nil
    }
    public func update(line: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        let upgrade = try await runner.run(["upgrade", "cliproxyapi"], limits: .upgrade, line: line)
        try Task.checkCancellation()
        guard upgrade.status == 0 else { throw HubCommandError.failed(upgrade.status) }
        let restart = try await runner.run(["services", "restart", "cliproxyapi"], limits: .inspection, line: line)
        try Task.checkCancellation()
        guard restart.status == 0 else { throw HubCommandError.failed(restart.status) }
    }
}

import Darwin

public struct HomebrewCommandRunner: HubCommandRunning {
    private let secrets: [String]
    public init(secrets: [String] = []) { self.secrets = secrets }

    // This trusts the user's Homebrew installation and everything it loads; it is not a sandbox.
    // Resolve and validate before EVERY command, including inspection and restart.
    static func validatedExecutable(_ path: String = "/opt/homebrew/bin/brew", root: String = "/opt/homebrew") throws -> String {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical.hasPrefix(root + "/") else { throw HubCommandError.unsafeExecutable }
        var info = stat()
        guard lstat(canonical, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0 || info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw HubCommandError.unsafeExecutable
        }
        var parent = URL(fileURLWithPath: canonical).deletingLastPathComponent()
        while true {
            guard stat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o002 == 0 else { throw HubCommandError.unsafeExecutable }
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
        return canonical
    }

    public func run(_ arguments: [String], limits: HubCommandLimits,
                    line: @escaping @Sendable (String) -> Void) async throws -> HubCommandResult {
        let executable = try Self.validatedExecutable()
        return try await execute(executable, arguments: arguments, limits: limits, line: line)
    }

    // Separate from validation to exercise the real pipe/process lifecycle with harmless fixtures.
    func execute(_ executable: String, arguments: [String], limits: HubCommandLimits,
                 line: @escaping @Sendable (String) -> Void) async throws -> HubCommandResult {
        let execution = HubCommandExecution(secrets: secrets, line: line)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(executable, arguments: arguments, limits: limits, continuation: continuation)
            }
        } onCancel: { execution.cancel() }
    }
}

/// All lifecycle state lives on one queue. Completion never waits for EOF: descendants may retain
/// the pipe. The dedicated POSIX process group lets cancellation reach Homebrew's children too.
private final class HubCommandExecution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "T3Proxy.Homebrew")
    private var pid: pid_t = 0
    private var reader: FileHandle?
    private var processSource: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<HubCommandResult, any Error>?
    private var cancelled = false
    private var stopping: HubCommandError?
    private var exited: Int32?
    private var output = Data(), pending = Data()
    private var dropping = false
    private var started = DispatchTime.now(), lastOutput = DispatchTime.now()
    private var limits = HubCommandLimits.inspection
    private let secrets: [String]
    private let line: @Sendable (String) -> Void
    init(secrets: [String], line: @escaping @Sendable (String) -> Void) { self.secrets = secrets; self.line = line }

    func start(_ executable: String, arguments: [String], limits: HubCommandLimits,
               continuation: CheckedContinuation<HubCommandResult, any Error>) {
        queue.async { [self] in
            self.continuation = continuation; self.limits = limits
            if cancelled { finish(error: .cancelled); return }
            let pipe = Pipe()
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
            posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
            posix_spawn_file_actions_addchdir(&actions, NSTemporaryDirectory())
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)
            var environment = ["PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())",
                               "TMPDIR=\(NSTemporaryDirectory())", "LANG=en_US.UTF-8", "HOMEBREW_NO_ENV_HINTS=1"]
            if arguments.first != "upgrade" { environment.append("HOMEBREW_NO_AUTO_UPDATE=1") }
            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            let env = environment.map { strdup($0) } + [nil]
            defer { for value in argv + env { free(value) } }
            let rc = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
                posix_spawn(&pid, executable, &actions, &attributes, a.baseAddress!, e.baseAddress!)
            } }
            pipe.fileHandleForWriting.closeFile()
            guard rc == 0 else { pipe.fileHandleForReading.closeFile(); finish(error: .launch(rc)); return }
            reader = pipe.fileHandleForReading
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            reader?.readabilityHandler = { [weak self] _ in
                self?.queue.async { [weak self] in self?.readAvailable() }
            }
            started = .now(); lastOutput = started
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            processSource = source
            source.setEventHandler { [self] in
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                processSource?.cancel(); processSource = nil
                exited = status == 0 ? 0 : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
                // Allow already queued pipe chunks to drain, but never depend on a child closing stdout.
                queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                    if stopping == nil { readAvailable(); finish() }
                }
            }
            source.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: 0.1)
            timer.setEventHandler { [self] in
                let now = DispatchTime.now().uptimeNanoseconds
                if Double(now - started.uptimeNanoseconds) / 1e9 >= limits.total ||
                    Double(now - lastOutput.uptimeNanoseconds) / 1e9 >= limits.silence { stop(.timedOut) }
            }
            timer.resume()
        }
    }
    func cancel() { queue.async { [self] in cancelled = true; if continuation != nil { stop(.cancelled) } } }
    private func stop(_ reason: HubCommandError) {
        guard stopping == nil, continuation != nil else { return }
        stopping = reason
        if pid > 0 { kill(-pid, SIGTERM) }
        queue.asyncAfter(deadline: .now() + limits.grace) { [self] in
            // Kill the group even if its leader already exited during the grace period.
            if pid > 0 { kill(-pid, SIGKILL) }
            finish(error: reason)
        }
    }
    private func readAvailable() {
        guard let reader, continuation != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Nonblocking reads and close run on the lifecycle queue, avoiding FileHandle close races.
        for _ in 0..<16 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(reader.fileDescriptor, $0.baseAddress!, $0.count) }
            if count > 0 { receive(Data(bytes.prefix(count))) }
            else {
                if count == 0 { reader.readabilityHandler = nil }
                return
            }
        }
    }
    private func receive(_ chunk: Data) {
        guard continuation != nil else { return }
        if chunk.isEmpty { reader?.readabilityHandler = nil; return }
        lastOutput = .now()
        if output.count < 2_000_000 { output.append(chunk.prefix(2_000_000 - output.count)) }
        for byte in chunk {
            if byte == 10 || byte == 13 { flushLine() }
            else if !dropping {
                pending.append(byte)
                if pending.count > 16_384 { pending.removeAll(keepingCapacity: true); dropping = true }
            }
        }
    }
    private func flushLine() {
        if dropping { line("[Long output line omitted]") }
        else if !pending.isEmpty { line(HubUpdateOutput.redact(String(decoding: pending, as: UTF8.self), secrets: secrets)) }
        pending.removeAll(keepingCapacity: true); dropping = false
    }
    private func finish(error: HubCommandError? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        // Keep the exit source until it reaps a terminated process, even after cancellation completes.
        if exited != nil || pid == 0 { processSource?.cancel(); processSource = nil }
        reader?.readabilityHandler = nil; try? reader?.close(); reader = nil
        flushLine()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: HubCommandResult(status: exited ?? 1, data: output)) }
    }
}
