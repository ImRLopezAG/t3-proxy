import Foundation
import Testing
@testable import T3ProxyCore

@Suite struct T3ProjectIconTests {
    @Test func monogramsFollowServerRules() {
        for (title, expected) in [("T3 Proxy", "T3"), ("orchestrator", "OR"), ("", "PR"), ("rosa v2", "RV"),
                                  ("  Ｔ３ Proxy  ", "T3"), ("!!!", "PR"), ("a", "AA"), ("Version42", "V4")] {
            #expect(T3ProjectMonogram.make(title).text == expected)
        }
        #expect(T3ProjectMonogram.make("").color == .fuchsia)
        #expect(T3ProjectMonogram.make("T3 Proxy").color == T3ProjectMonogram.make("t3 proxy").color)
    }

    @Test func decodesIconsWithoutBreakingProjects() throws {
        let fixtures: [(String, T3ProjectIcon?)] = [
            (#"{"kind":"lucide","name":"terminal","color":"blue"}"#, .lucide(name: "terminal", color: .blue)),
            (#"{"kind":"emoji","emoji":"🦊"}"#, .emoji("🦊")),
            (#"{"kind":"monogram","text":"TP","color":"rose"}"#, .monogram(text: "TP", color: .rose)),
            (#"{"kind":"lucide","name":"terminal","color":"green","monogramText":"AB"}"#, .monogram(text: "AB", color: .green)),
            (#"{"kind":"lucide","name":"terminal","color":"green","monogram":"CD"}"#, .monogram(text: "CD", color: .green)),
            (#"{"kind":"future","color":"blue"}"#, nil),
            (#"{"kind":"lucide","name":"terminal","color":"future"}"#, nil),
            (#"{"kind":"monogram","color":"blue"}"#, nil),
            (#"null"#, nil), (#"42"#, nil),
        ]
        for (icon, expected) in fixtures {
            let data = Data(#"{"id":"p","title":"Project","workspaceRoot":"/sample","faviconPath":"public/icon.svg","projectIcon":\#(icon)}"#.utf8)
            let p = try JSONDecoder().decode(T3CodeProject.self, from: data)
            #expect(p.projectIcon == expected)
            #expect(p.faviconPath == "public/icon.svg" && p.workspaceRoot == "/sample")
        }
        let p = try JSONDecoder().decode(T3CodeProject.self, from: Data(#"{"id":"p","title":"Project"}"#.utf8))
        #expect(p.projectIcon == nil && p.faviconPath == nil)
    }

    @Test func faviconCandidateExplicitPrecedenceAndCache() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("t3icons-\(UUID())")
        try fm.createDirectory(at: root.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let candidate = root.appendingPathComponent("public/favicon.svg")
        try Data("<svg/>".utf8).write(to: candidate)
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: nil) == candidate.resolvingSymlinksInPath())
        let explicit = root.appendingPathComponent("custom.png")
        try Data([0]).write(to: explicit)
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: "custom.png") == explicit.resolvingSymlinksInPath())
        // The nil result has a short cache lifetime; adding a candidate doesn't trigger another scan immediately.
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(T3ProjectFavicon.resolve(workspaceRoot: empty.path, faviconPath: nil) == nil)
        try Data([0]).write(to: empty.appendingPathComponent("favicon.png"))
        #expect(T3ProjectFavicon.resolve(workspaceRoot: empty.path, faviconPath: nil) == nil)
    }

    @Test func faviconRejectsEscapesNonImagesAndOversizedFiles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("t3icons-\(UUID())")
        let root = base.appendingPathComponent("root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside.svg")
        try Data([0]).write(to: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("favicon.svg"), withDestinationURL: outside)
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: nil) == nil)
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: "../outside.svg") == nil)
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: outside.path) == nil)
        try Data([0]).write(to: root.appendingPathComponent("notes.txt"))
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: "notes.txt") == nil)
        try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: root.appendingPathComponent("large.png"))
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: "large.png") == nil)
        try fm.createDirectory(at: root.appendingPathComponent("directory.png"), withIntermediateDirectories: true)
        #expect(T3ProjectFavicon.resolve(workspaceRoot: root.path, faviconPath: "directory.png") == nil)
    }

    @Test func faviconBytesAreReadOnceThroughAContainedDescriptor() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("t3iconbytes-\(UUID())")
        let root = base.appendingPathComponent("root")
        try fm.createDirectory(at: root.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let icon = root.appendingPathComponent("public/favicon.svg")
        try Data("<svg/>".utf8).write(to: icon)
        #expect(T3ProjectFavicon.load(workspaceRoot: root.path, faviconPath: nil) == Data("<svg/>".utf8))
        // Swapping the file for a symlink to something outside afterwards never reaches the outside file:
        // the cache holds the validated bytes, and a fresh read refuses the link.
        let outside = base.appendingPathComponent("secret.svg")
        try Data("secret".utf8).write(to: outside)
        try fm.removeItem(at: icon)
        try fm.createSymbolicLink(at: icon, withDestinationURL: outside)
        #expect(T3ProjectFavicon.load(workspaceRoot: root.path, faviconPath: nil) == Data("<svg/>".utf8))
        let prefix = try #require(T3ProjectFavicon.canonicalPrefix(root.path))
        #expect(T3ProjectFavicon.readContained(icon, rootPrefix: prefix) == nil)
        // Oversized files are refused by the descriptor check too.
        let big = root.appendingPathComponent("big.png")
        try Data(repeating: 1, count: T3ProjectFavicon.maxBytes + 1).write(to: big)
        #expect(T3ProjectFavicon.readContained(big.resolvingSymlinksInPath(), rootPrefix: prefix) == nil)
    }

}
