import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

// Read-only inspection of T3 Code's local files (~/.t3/userdata) and the provider homes it points at.
// Nothing here writes outside the repo. Secrets are reduced to SHA-256 digests on read and never
// appear in any value this file returns; every user-facing string is built from fixed phrases,
// host:port pairs, paths and instance names only.

// MARK: - Server runtime

public struct T3CodeRuntime: Sendable, Equatable {
    public let pid: Int32?
    public let host: String?
    public let port: Int?
    public let origin: String?
    public let serverVersion: String?
    public let startedAt: Date?

    /// Parses `server-runtime.json`. Unknown or mistyped fields become nil; non-object input is nil.
    public static func parse(_ data: Data) -> T3CodeRuntime? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let pid = (root["pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.intValue) }
        return T3CodeRuntime(pid: pid.flatMap { $0 > 0 ? $0 : nil },
                             host: root["host"] as? String,
                             port: (root["port"] as? NSNumber)?.intValue,
                             origin: root["origin"] as? String,
                             serverVersion: root["serverVersion"] as? String,
                             startedAt: (root["startedAt"] as? String).flatMap(T3CodeLocal.date))
    }

    /// True when the server listens on anything but loopback (0.0.0.0, ::, a LAN address, a name).
    public var exposed: Bool { host.map { !T3CodeLocal.isLoopback($0) } ?? false }
}

// MARK: - Provider configs

public enum T3CodeProviderKind: String, Sendable { case claude, codex }

/// What a provider home is configured to call. `keyDigest` is SHA-256 of the client key; the key itself is dropped.
public struct T3CodeProviderConfig: Sendable, Equatable {
    public let kind: T3CodeProviderKind
    public let configPath: String
    public let fileFound: Bool
    public let baseURL: String?
    /// Plain description of where the key comes from, e.g. "env_key CLIPROXY_API_KEY from auth.json". Never the value.
    public let keySource: String?
    public let keyDigest: Data?
    /// False when the key was found somewhere T3 Code's launch may not actually read it (so a match isn't proof).
    public var keyVerified: Bool = true
}

public struct T3CodeProviderInstance: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let driver: String
    public let enabled: Bool
    public let homePath: String?
    /// The provider's launcher (`config.binaryPath`), e.g. a wrapper script that exports the key.
    public var binaryPath: String? = nil
    public var kind: T3CodeProviderKind? {
        switch driver.lowercased() {
        case "claudeagent", "claude": .claude
        case "codex": .codex
        default: nil
        }
    }
}

public struct T3CodeLimitSource: Sendable, Equatable {
    public let id: String
    public let kind: String
    public let url: String
    public let enabled: Bool
}

public struct T3CodeSettings: Sendable, Equatable {
    public let instances: [T3CodeProviderInstance]
    public let limitSources: [T3CodeLimitSource]

    /// Reads only `providerInstances` and `usageLimitSources` (kind/url/enabled). Other fields, including
    /// any stored management key, are never copied out.
    public static func parse(_ data: Data, home: String) -> T3CodeSettings? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var instances: [T3CodeProviderInstance] = []
        for (id, value) in (root["providerInstances"] as? [String: Any]) ?? [:] {
            guard let o = value as? [String: Any] else { continue }
            let config = o["config"] as? [String: Any]
            let homePath = (config?["homePath"] as? String).flatMap { $0.isEmpty ? nil : T3CodeLocal.expand($0, home: home) }
            let binaryPath = (config?["binaryPath"] as? String).flatMap { $0.isEmpty ? nil : T3CodeLocal.expand($0, home: home) }
            instances.append(.init(id: id, displayName: (o["displayName"] as? String) ?? id, driver: (o["driver"] as? String) ?? "",
                                   enabled: (o["enabled"] as? Bool) ?? true, homePath: homePath, binaryPath: binaryPath))
        }
        var sources: [T3CodeLimitSource] = []
        for (id, value) in (root["usageLimitSources"] as? [String: Any]) ?? [:] {
            guard let o = value as? [String: Any], let url = o["url"] as? String else { continue }
            sources.append(.init(id: id, kind: (o["kind"] as? String) ?? "", url: url, enabled: (o["enabled"] as? Bool) ?? true))
        }
        return T3CodeSettings(instances: instances.sorted { $0.id < $1.id }, limitSources: sources.sorted { $0.id < $1.id })
    }
}

// MARK: - Checks and summary

public enum T3CodeCheckState: Sendable, Equatable { case ok, warning, problem }

public struct T3CodeCheck: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let state: T3CodeCheckState
    public let message: String
}

/// Hub client keys as digests, or why they could not be read. No request is made for `.noKey`/`.rejected`.
public enum T3CodeHubKeys: Sendable, Equatable {
    case digests(Set<Data>)
    case noKey
    case rejected
    case failed
}

/// Compact model for other UI (menu bar, panel).
public struct T3CodeLocalStatus: Sendable, Equatable {
    public let runtimeFound: Bool
    public let running: Bool
    public let version: String?
    public let startedAt: Date?
    public let host: String?
    public let port: Int?
    public let exposed: Bool
    public let checks: [T3CodeCheck]
    public var problems: Int { checks.filter { $0.state != .ok }.count }
    public var summary: String {
        switch problems {
        case 0: "All connected"
        case 1: "1 problem"
        default: "\(problems) problems"
        }
    }
}

public struct T3CodePaths: Sendable {
    public let home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }
    public var userdata: String { (home as NSString).appendingPathComponent(".t3/userdata") }
    public var runtime: String { (userdata as NSString).appendingPathComponent("server-runtime.json") }
    public var settings: String { (userdata as NSString).appendingPathComponent("settings.json") }
}

public enum T3CodeLocal {
    /// The configured hub port (Settings → Connection).
    public static var hubPort: Int { HubPort.current() }

    // MARK: helpers

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }

    /// Literal loopback only: `localhost`, `::1`, or a dotted-quad 127.x.y.z. Names such as `127.example.com` are not.
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        if h == "localhost" || h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { p in !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber) && Int(p)! <= 255 }
    }

    /// The address to actually dial for a loopback host: names are pinned to a literal, never resolved.
    static func loopbackLiteral(_ host: String) -> String? {
        guard isLoopback(host) else { return nil }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        return h == "localhost" ? "127.0.0.1" : h.contains(":") ? "::1" : h
    }

    /// True for http(s)://127.0.0.1|localhost|[::1]:8317 with any path.
    public static func pointsAtHub(_ url: String?, port: Int = hubPort) -> Bool {
        guard let url, let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, isLoopback(host), c.port == port else { return false }
        return true
    }

    public static func digest(_ key: String) -> Data {
        Data(SHA256.hash(data: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)))
    }

    public static func pidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func hostPort(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host else { return nil }
        let port = c.port ?? (c.scheme == "https" ? 443 : 80)
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func read(_ path: String) -> Data? {
        guard let d = FileManager.default.contents(atPath: path), d.count < 4 << 20 else { return nil }
        return d
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: Claude

    /// `<home>/settings.json`: `env.ANTHROPIC_BASE_URL` and `env.ANTHROPIC_AUTH_TOKEN` (or `ANTHROPIC_API_KEY`).
    public static func readClaude(home: String) -> T3CodeProviderConfig {
        let path = (home as NSString).appendingPathComponent("settings.json")
        guard let data = read(path) else {
            return .init(kind: .claude, configPath: path, fileFound: false, baseURL: nil, keySource: nil, keyDigest: nil)
        }
        let env = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["env"] as? [String: Any] ?? [:]
        var source: String?, digest: Data?
        for name in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"] {
            if let v = nonEmpty(env[name] as? String) { source = "env \(name) in settings.json"; digest = self.digest(v); break }
        }
        return .init(kind: .claude, configPath: path, fileFound: true, baseURL: nonEmpty(env["ANTHROPIC_BASE_URL"] as? String),
                     keySource: source, keyDigest: digest)
    }

    // MARK: Codex

    /// Minimal TOML: `[table]` headers (dotted, optionally quoted parts) and `key = "string"` / bare values.
    /// Arrays of tables, multi-line strings and inline tables are skipped, not parsed.
    static func parseTOML(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var table = ""
        var inMultiline: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let delim = inMultiline { if line.contains(delim) { inMultiline = nil }; continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") { table = "\u{0}array"; continue }
            if line.hasPrefix("[") {
                guard let end = line.lastIndex(of: "]") else { table = "\u{0}bad"; continue }
                table = tableName(String(line[line.index(after: line.startIndex)..<end]))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = unquote(line[..<eq].trimmingCharacters(in: .whitespaces))
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            for delim in ["\"\"\"", "'''"] where value.hasPrefix(delim) {
                if value.dropFirst(3).contains(delim) { value = String(value.dropFirst(3).prefix { $0 != delim.first! }) }
                else { inMultiline = delim; value = "" }
            }
            if inMultiline != nil { continue }
            out[table, default: [:]][key] = scalar(value)
        }
        return out
    }

    private static func tableName(_ s: String) -> String {
        var parts: [String] = [], cur = "", quote: Character?
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "." { parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur.trimmingCharacters(in: .whitespaces))
        return parts.joined(separator: ".")
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { return String(s.dropFirst().dropLast()) }
        return s
    }

    private static func scalar(_ v: String) -> String {
        guard let f = v.first else { return "" }
        if f == "\"" || f == "'" {
            var out = "", escaped = false
            for ch in v.dropFirst() {
                if escaped { out.append(ch); escaped = false; continue }
                if ch == "\\" && f == "\"" { escaped = true; continue }
                if ch == f { return out }
                out.append(ch)
            }
            return out
        }
        if f == "{" || f == "[" { return "" }
        return String(v.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// `<home>/config.toml`: top-level `model_provider`, its `[model_providers.<id>]` `base_url`, and the key.
    /// The key counts as verified only from `experimental_bearer_token` or from what the launcher script
    /// (`binaryPath`) exports for `env_key`, i.e. what T3 Code's Codex process will really see. A value found
    /// elsewhere (auth.json, a stray key file, this app's own environment) is reported but marked unverified.
    public static func readCodex(home: String, launcher: String? = nil, userHome: String = NSHomeDirectory(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> T3CodeProviderConfig {
        let path = (home as NSString).appendingPathComponent("config.toml")
        guard let data = read(path), let text = String(data: data, encoding: .utf8) else {
            return .init(kind: .codex, configPath: path, fileFound: false, baseURL: nil, keySource: nil, keyDigest: nil)
        }
        let toml = parseTOML(text)
        let providerID = nonEmpty(toml[""]?["model_provider"]) ?? "openai"
        let provider = toml["model_providers.\(providerID)"] ?? [:]
        let baseURL = nonEmpty(provider["base_url"]) ?? (providerID == "openai" ? nonEmpty(toml[""]?["openai_base_url"]) : nil)
        var source: String?, digest: Data?, verified = true
        if let token = nonEmpty(provider["experimental_bearer_token"]) {
            source = "bearer token in config.toml"; digest = self.digest(token)
        } else if let envKey = nonEmpty(provider["env_key"]) ?? (providerID == "openai" ? "OPENAI_API_KEY" : nil) {
            let auth = read((home as NSString).appendingPathComponent("auth.json"))
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            if let exported = launcher.flatMap({ launcherExport(envKey, script: $0, userHome: userHome) }) {
                source = "\(envKey) from the launcher (\(exported.from))"; digest = exported.value.map(self.digest)
                if exported.value == nil { source = "\(envKey) from the launcher (\(exported.from), unreadable)" }
            } else if envKey == "OPENAI_API_KEY", let v = nonEmpty(auth[envKey] as? String) {
                // Codex itself reads OPENAI_API_KEY from auth.json.
                source = "\(envKey) from auth.json"; digest = self.digest(v)
            } else if let v = nonEmpty(auth[envKey] as? String) {
                source = "\(envKey) from auth.json"; digest = self.digest(v); verified = false
            } else if let v = nonEmpty(read((home as NSString).appendingPathComponent("proxy-key")).flatMap { String(data: $0, encoding: .utf8) }) {
                source = "\(envKey) from proxy-key file"; digest = self.digest(v); verified = false
            } else if let v = nonEmpty(environment[envKey]) {
                source = "\(envKey) from this app's environment"; digest = self.digest(v); verified = false
            } else {
                source = "\(envKey) (value not found)"
            }
        }
        var cfg = T3CodeProviderConfig(kind: .codex, configPath: path, fileFound: true, baseURL: baseURL, keySource: source, keyDigest: digest)
        cfg.keyVerified = verified
        return cfg
    }

    /// What a shell launcher exports for `name`: `export NAME="$(cat "<file>")"` (file read, `$HOME`/`~` expanded)
    /// or `export NAME="literal"`. `from` describes the source without the value; `value` is nil if unreadable.
    /// `userHome` is what `$HOME`/`~` mean inside the script: the user's home, not the provider's home folder.
    static func launcherExport(_ name: String, script: String, userHome home: String) -> (from: String, value: String?)? {
        guard let data = read(script), data.count < 64 << 10, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#!") else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("export ") else { continue }
            line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(name + "=") else { continue }
            var rhs = String(line.dropFirst(name.count + 1))
            if rhs.count >= 2, let q = rhs.first, q == "\"" || q == "'", rhs.last == q { rhs = String(rhs.dropFirst().dropLast()) }
            if rhs.hasPrefix("$(cat "), rhs.hasSuffix(")") {
                var file = String(rhs.dropFirst(6).dropLast()).trimmingCharacters(in: .whitespaces)
                file = file.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                file = file.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
                file = expand(file, home: home)
                guard file.hasPrefix("/") else { return ("a command in the launcher", nil) }
                let value = nonEmpty(read(file).flatMap { String(data: $0, encoding: .utf8) })
                return ((file as NSString).lastPathComponent, value)
            }
            if rhs.contains("$") || rhs.contains("`") { return ("a command in the launcher", nil) }
            return ("a value in the launcher", nonEmpty(rhs))
        }
        return nil
    }

    // MARK: Reachability

    /// Unauthenticated GET to the URL's origin, loopback only. Any HTTP status counts as "answers". No key is sent.
    public static func probe(_ url: String, protocolClasses: [AnyClass]? = nil) async -> Bool {
        guard var c = URLComponents(string: url), let host = c.host, isLoopback(host),
              c.scheme == "http" || c.scheme == "https" else { return false }
        guard let literal = loopbackLiteral(host) else { return false }
        c.host = literal
        c.path = "/"; c.query = nil; c.fragment = nil; c.user = nil; c.password = nil
        guard let target = c.url else { return false }
        var r = URLRequest(url: target, timeoutInterval: 3)
        r.httpMethod = "GET"
        let session = loopbackSession(timeout: 3, protocolClasses: protocolClasses)
        defer { session.invalidateAndCancel() }
        guard let (_, resp) = try? await session.data(for: r) else { return false }
        return resp is HTTPURLResponse
    }

    // MARK: Assembly

    /// Pure: builds the summary from already-read inputs. Easy to test, no I/O.
    public static func evaluate(runtime: T3CodeRuntime?, alive: Bool, settings: T3CodeSettings?,
                                configs: [String: T3CodeProviderConfig], hubKeys: T3CodeHubKeys,
                                limitAnswers: [String: Bool], hubPort: Int = hubPort) -> T3CodeLocalStatus {
        var checks: [T3CodeCheck] = []
        if settings == nil {
            checks.append(.init(id: "settings", title: "T3 Code settings", state: .problem,
                                message: "Couldn't read T3 Code's settings.json."))
        }
        let instances = (settings?.instances ?? []).filter { $0.enabled && $0.homePath != nil && $0.kind != nil }
        if settings != nil && instances.isEmpty {
            checks.append(.init(id: "instances", title: "Provider instances", state: .warning,
                                message: "No enabled provider instance has its own home folder."))
        }
        for inst in instances {
            guard let cfg = configs[inst.id] else { continue }
            let file = (cfg.configPath as NSString).lastPathComponent
            let urlCheck: T3CodeCheck
            if !cfg.fileFound {
                urlCheck = .init(id: "\(inst.id).url", title: inst.displayName, state: .problem,
                                 message: "No \(file) in \(inst.homePath ?? "its home folder").")
            } else if pointsAtHub(cfg.baseURL, port: hubPort) {
                urlCheck = .init(id: "\(inst.id).url", title: inst.displayName, state: .ok,
                                 message: "Points at the hub (\(hostPort(cfg.baseURL!) ?? "127.0.0.1:\(hubPort)")).")
            } else if let u = cfg.baseURL {
                urlCheck = .init(id: "\(inst.id).url", title: inst.displayName, state: .problem,
                                 message: "Points at \(hostPort(u) ?? "another address"), not the hub on 127.0.0.1:\(hubPort).")
            } else {
                urlCheck = .init(id: "\(inst.id).url", title: inst.displayName, state: .problem,
                                 message: "\(file) has no base URL, so it calls the provider directly.")
            }
            checks.append(urlCheck)
            guard cfg.fileFound else { continue }
            let keyTitle = "\(inst.displayName) key"
            let keyCheck: T3CodeCheck
            if let d = cfg.keyDigest {
                switch hubKeys {
                case .digests(let set):
                    if !cfg.keyVerified {
                        // Found somewhere T3 Code's launch may not read, so neither result is proof.
                        keyCheck = .init(id: "\(inst.id).key", title: keyTitle, state: .warning,
                                         message: "\(set.contains(d) ? "A key the hub accepts" : "A key the hub doesn't know") was found (\(cfg.keySource ?? "unknown source")), but T3 Code may not use it.")
                    } else {
                        keyCheck = set.contains(d)
                            ? .init(id: "\(inst.id).key", title: keyTitle, state: .ok, message: "Key accepted by the hub.")
                            : .init(id: "\(inst.id).key", title: keyTitle, state: .problem, message: "Key not in the hub's client keys.")
                    }
                case .noKey:
                    keyCheck = .init(id: "\(inst.id).key", title: keyTitle, state: .warning, message: "Can't check: no management key.")
                case .rejected:
                    keyCheck = .init(id: "\(inst.id).key", title: keyTitle, state: .warning, message: "Can't check: the management key was rejected.")
                case .failed:
                    keyCheck = .init(id: "\(inst.id).key", title: keyTitle, state: .warning, message: "Can't check: the hub didn't return its client keys.")
                }
            } else {
                keyCheck = .init(id: "\(inst.id).key", title: keyTitle, state: .problem,
                                 message: cfg.keySource.map { "No key found (\($0))." } ?? "No client key configured.")
            }
            checks.append(keyCheck)
        }
        for src in (settings?.limitSources ?? []) where src.enabled && src.kind == "cliproxy" {
            // Never fall back to the raw setting: a malformed URL could carry a password or token.
            let hp = hostPort(src.url) ?? "an invalid address"
            let port = URLComponents(string: src.url)?.port
            let title = port == 8318 ? "T3 Code limit bars read from Proxy Deck (8318)" : "T3 Code limit bars read from \(hp)"
            let answers = limitAnswers[src.id] ?? false
            let local = URLComponents(string: src.url)?.host.map(isLoopback) ?? false
            checks.append(.init(id: "limit.\(src.id)", title: title, state: answers ? .ok : .problem,
                                message: answers ? "Something answers at \(hp)."
                                    : local ? "Nothing answers at \(hp)." : "\(hp) is not on this Mac, so it wasn't checked."))
        }
        return T3CodeLocalStatus(runtimeFound: runtime != nil, running: alive, version: runtime?.serverVersion,
                                 startedAt: runtime?.startedAt, host: runtime?.host, port: runtime?.port,
                                 exposed: runtime?.exposed ?? false, checks: checks)
    }

    /// Reads the files, probes limit sources, and asks `hubKeys` only when an instance has a key to compare.
    public static func inspect(paths: T3CodePaths = .init(), hubKeys: @Sendable () async -> T3CodeHubKeys) async -> T3CodeLocalStatus {
        let (runtime, settings, configs) = await Task.detached(priority: .utility) { () -> (T3CodeRuntime?, T3CodeSettings?, [String: T3CodeProviderConfig]) in
            let runtime = read(paths.runtime).flatMap(T3CodeRuntime.parse)
            let settings = read(paths.settings).flatMap { T3CodeSettings.parse($0, home: paths.home) }
            var configs: [String: T3CodeProviderConfig] = [:]
            for inst in settings?.instances ?? [] where inst.enabled {
                guard let home = inst.homePath, let kind = inst.kind else { continue }
                configs[inst.id] = kind == .claude ? readClaude(home: home) : readCodex(home: home, launcher: inst.binaryPath)
            }
            return (runtime, settings, configs)
        }.value
        let alive = runtime?.pid.map(pidAlive) ?? false
        let keys: T3CodeHubKeys = configs.values.contains { $0.keyDigest != nil } ? await hubKeys() : .failed
        var answers: [String: Bool] = [:]
        for src in settings?.limitSources ?? [] where src.enabled && src.kind == "cliproxy" {
            answers[src.id] = await probe(src.url)
        }
        return evaluate(runtime: runtime, alive: alive, settings: settings, configs: configs, hubKeys: keys, limitAnswers: answers)
    }
}

// MARK: - Hub client keys (digests only)

extension ManagementClient {
    /// GET the hub config and return SHA-256 digests of `access.api-keys` (or legacy top-level `api-keys`).
    /// The raw keys are discarded inside this function.
    public func clientKeyDigests(key: String) async throws -> Set<Data> {
        try T3CodeLocal.clientKeyDigests(fromConfig: await send("GET", "v8/management/config", nil, key: key))
    }
}

extension T3CodeLocal {
    static func clientKeyDigests(fromConfig data: Data) throws -> Set<Data> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProxyError.incompatible }
        let list = ((root["access"] as? [String: Any])?["api-keys"] as? [Any]) ?? (root["api-keys"] as? [Any]) ?? []
        return Set(list.compactMap { $0 as? String }.filter { !$0.isEmpty }.map(digest))
    }
}

@MainActor
extension Monitor {
    /// Hub client-key digests without ever sending a missing or rejected management key.
    public func t3CodeHubKeys() async -> T3CodeHubKeys {
        guard hasKey else { return .noKey }
        if management == .rejected { return .rejected }
        do { return .digests(try await self.management { try await $0.clientKeyDigests(key: $1) }) }
        catch ManagementError.locked { return .rejected }
        catch ProxyError.unauthorized { return .rejected }
        catch { return .failed }
    }
}
