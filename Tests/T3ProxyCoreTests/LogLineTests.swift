import Testing
@testable import T3ProxyCore

@Suite struct LogLineTests {
    @Test func accessLine() throws {
        let l = LogLine(#"[2026-11-06 13:32:39] [--------] [info ] [gin_logger.go:113] 200 |         102ms |       127.0.0.1 | GET     "/v0/management/auth-files""#)
        #expect(l.time == "2026-11-06 13:32:39" && l.requestID == nil && l.level == .info && l.source == "gin_logger.go:113")
        let a = try #require(l.access)
        #expect(a.status == 200 && a.latency == "102ms" && a.latencyMs == 102 && a.clientIP == "127.0.0.1" && a.method == "GET")
        #expect(a.path == "/v0/management/auth-files" && l.detail == a.path && l.isManagementCall)
    }

    @Test func messageLine() {
        let l = LogLine("[2026-11-06 13:32:40] [bdbd622f] [info ] [selector.go:1203] session-affinity: cache hit | session=codex:01 auth=x provider=mixed model=gpt-6-astra")
        #expect(l.requestID == "bdbd622f" && l.source == "selector.go:1203" && l.access == nil)
        #expect(l.text == "session-affinity: cache hit | session=codex:01 auth=x provider=mixed model=gpt-6-astra" && l.detail == l.text)
        #expect(!l.isManagementCall)
    }

    @Test func unknownShapesFallBack() {
        for raw in ["", "panic: boom", "[", "[2026-11-06 13:32:40] [warn ] [no pe] x", "[2026-11-06 13:32:40] [error] 999 | a | b | GET /x",
                    "[2026-11-06 13:32:40] [info] [a.go:1] 200 | 1ms | ip | get \"/x\"", String(repeating: "[|", count: 2000)] {
            let l = LogLine(raw)
            #expect(l.access == nil)
            #expect(!l.detail.isEmpty || raw.isEmpty)
        }
        let n = LogLine("[2026-11-06 13:32:40] [warn ] [no pe] x")
        #expect(n.source == nil && n.text == "[no pe] x" && n.level == .warn)
    }

    @Test func durations() {
        #expect(LogLine.goDurationMs("1.5s") == 1500)
        #expect(LogLine.goDurationMs("1m2s") == 62000)
        #expect(LogLine.goDurationMs("250µs") == 0.25)
        #expect(abs((LogLine.goDurationMs("800ns") ?? 0) - 0.0008) < 1e-12)
        #expect(LogLine.goDurationMs("1h") == 3_600_000)
        #expect(LogLine.goDurationMs("fast") == nil && LogLine.goDurationMs("") == nil && LogLine.goDurationMs("12") == nil)
    }

    @Test func hideManagementFilter() {
        let m = LogLine(#"[2026-11-06 13:32:39] [--------] [info ] [gin_logger.go:113] 200 | 1ms | 127.0.0.1 | GET "/v8/management/config""#, seq: 1)
        let p = LogLine(#"[2026-11-06 13:32:39] [abcd1234] [info ] [gin_logger.go:113] 502 | 3.1s | 127.0.0.1 | POST "/v1/chat/completions""#, seq: 2)
        #expect(LogLine.filter([m, p], level: nil, query: "").count == 2)
        #expect(LogLine.filter([m, p], level: nil, query: "", hideManagement: true) == [p])
        #expect(LogLine.filter([m, p], level: nil, query: "abcd1234") == [p])
        #expect(p.access?.status == 502 && p.access?.latencyMs == 3100)
    }
}
