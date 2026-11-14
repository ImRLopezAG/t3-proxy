import Foundation
import Darwin
import T3ProxyCore

@main struct ConnectorMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.count >= 6, args[1] == "launch" {
            launch(Array(args.dropFirst(2)))
            return
        }
        guard args.count == 3, args[1] == "connect", let id = UUID(uuidString: args[2]) else {
            FileHandle.standardError.write(Data("Usage: T3Connectors connect <connection-id>\n".utf8)); exit(2)
        }
        let relay: ManagedMCPRelay
        do { relay = try ManagedMCPRelay(id: id) }
        catch { FileHandle.standardError.write(Data("The managed MCP connection is unavailable. Check it in T3 Proxy.\n".utf8)); exit(1) }
        let session = ManagedMCPSession(relay)
        defer { session.finish() }
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count <= 0 { break }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count <= 1024 * 1024 else { exit(2) }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                session.submit(line) { FileHandle.standardOutput.write($0 + Data([10])) }
            }
        }
    }
    static func launch(_ args: [String]) {
        guard args.count >= 4, ["codex", "claude"].contains(args[0]), args[1].hasPrefix("/"), args[2].hasPrefix("/"), let port = Int(args[3]), HubPort.isValid(port) else { exit(2) }
        let kind = args[0], home = args[1], binary = args[2]
        let keyName = kind == "codex" ? "CLIPROXY_API_KEY" : "ANTHROPIC_AUTH_TOKEN"
        let ambient = ProcessInfo.processInfo.environment[keyName]
        let stored = try? ConnectorCredentialStore(account: "hub-inference").load()
        guard let key = ambient.flatMap({ $0.isEmpty ? nil : $0 }) ?? stored?.accessToken, !key.isEmpty else {
            FileHandle.standardError.write(Data("Save a hub inference key in T3 Proxy → Connectors → Setup.\n".utf8)); exit(1)
        }
        setenv(keyName, key, 1)
        setenv(kind == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR", home, 1)
        if kind == "claude" { setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(port)", 1) }
        let argv = ([binary] + args.dropFirst(4)).map { strdup($0) } + [nil]
        argv.withUnsafeBufferPointer { _ = execv(binary, $0.baseAddress!) }
        for pointer in argv { if let pointer { free(pointer) } }
        FileHandle.standardError.write(Data("The configured client executable could not be started.\n".utf8)); exit(1)
    }
}
