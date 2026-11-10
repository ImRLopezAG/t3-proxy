import Foundation

public enum T3ProjectIconColor: String, Sendable, CaseIterable {
    case gray, red, orange, amber, yellow, lime, green, emerald, teal, cyan, sky, blue, indigo, violet, purple, fuchsia, pink, rose
}

public enum T3ProjectIcon: Sendable, Equatable, Decodable {
    case lucide(name: String, color: T3ProjectIconColor)
    case emoji(String)
    case monogram(text: String, color: T3ProjectIconColor)

    private enum CodingKeys: String, CodingKey { case kind, name, color, emoji, text, monogramText, monogram }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "emoji" { self = .emoji(try c.decode(String.self, forKey: .emoji)); return }
        guard kind == "lucide" || kind == "monogram",
              let color = T3ProjectIconColor(rawValue: try c.decode(String.self, forKey: .color)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown project icon or color")
        }
        if kind == "monogram" {
            self = .monogram(text: try c.decode(String.self, forKey: .text), color: color)
        } else if let text = (try? c.decodeIfPresent(String.self, forKey: .monogramText))
                    ?? (try? c.decodeIfPresent(String.self, forKey: .monogram)) {
            self = .monogram(text: text, color: color)
        } else { self = .lucide(name: try c.decode(String.self, forKey: .name), color: color) }
    }
}

public enum T3ProjectMonogram {
    public static func make(_ title: String) -> (text: String, color: T3ProjectIconColor) {
        let normalized = title.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
        let words = pattern.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).compactMap {
            Range($0.range, in: normalized).map { String(normalized[$0]) }
        }
        var text = "PR"
        if let firstWord = words.first, let first = firstWord.first {
            let second = firstWord.dropFirst().first(where: \.isNumber)
                ?? (words.count > 1 ? words.last?.first : firstWord.last)
            text = String((String(first) + (second.map(String.init) ?? "")).uppercased().prefix(2))
        }
        let seed = (title.isEmpty ? "project" : title).lowercased(with: Locale(identifier: "en_US"))
        let index = seed.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 18 }
        return (text, T3ProjectIconColor.allCases[index])
    }
}

public enum T3ProjectFavicon {
    private static let cache = FaviconCache()
    public static func resolve(workspaceRoot: String, faviconPath: String?) -> URL? {
        cache.resolve(workspaceRoot: workspaceRoot, faviconPath: faviconPath)
    }
    /// The favicon's bytes, read once through a descriptor that is re-checked after opening (regular file, still
    /// inside the root, at most 4 MB), and cached as bytes, so a later swap of the file or a parent for a symlink or
    /// a large file is never followed.
    public static func load(workspaceRoot: String, faviconPath: String?) -> Data? {
        cache.load(workspaceRoot: workspaceRoot, faviconPath: faviconPath)
    }
    static let maxBytes = 4 * 1024 * 1024

    /// The root as the kernel names it (realpath keeps "/private"; Foundation's symlink resolution strips it), with "/".
    static func canonicalPrefix(_ root: String) -> String? {
        guard let p = realpath(root, nil) else { return nil }
        defer { free(p) }
        let s = String(cString: p)
        return s.hasSuffix("/") ? s : s + "/"
    }

    /// Opens without following a final symlink, then validates what was actually opened.
    static func readContained(_ url: URL, rootPrefix: String) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, st.st_size <= maxBytes else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { return nil }
        let opened = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard opened.hasPrefix(rootPrefix) else { return nil }
        var data = Data(count: maxBytes + 1)
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, maxBytes + 1) }
        guard n > 0, n <= maxBytes else { return nil }
        data.count = n
        return data
    }
}

private final class FaviconCache: @unchecked Sendable {
    private struct Key: Hashable { let root: String; let path: String? }
    private struct Entry { let url: URL?; let expires: Date }
    private struct DataEntry { let data: Data?; let expires: Date }
    private var bytes: [Key: DataEntry] = [:]

    func load(workspaceRoot: String, faviconPath: String?) -> Data? {
        let key = Key(root: workspaceRoot, path: faviconPath), now = Date()
        if let cached = lock.withLock({ bytes[key] }), cached.expires > now { return cached.data }
        let data = T3ProjectFavicon.canonicalPrefix(workspaceRoot).flatMap { prefix in
            resolve(workspaceRoot: workspaceRoot, faviconPath: faviconPath).flatMap { T3ProjectFavicon.readContained($0, rootPrefix: prefix) }
        }
        lock.withLock {
            bytes = bytes.filter { $0.value.expires > now }
            bytes[key] = DataEntry(data: data, expires: now.addingTimeInterval(data == nil ? 60 : 600))
        }
        return data
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private let extensions: Set<String> = ["avif", "gif", "icns", "ico", "jpg", "jpeg", "png", "svg", "webp"]
    private let candidates = [
        "favicon.svg", "favicon.ico", "favicon.png", "public/favicon.svg", "public/favicon.ico", "public/favicon.png",
        "app/favicon.ico", "app/favicon.png", "app/icon.svg", "app/icon.png", "app/icon.ico", "src/favicon.ico",
        "src/favicon.svg", "src/app/favicon.ico", "src/app/icon.svg", "src/app/icon.png", "assets/icon.svg",
        "assets/icon.png", "assets/logo.svg", "assets/logo.png", ".idea/icon.svg", "Resources/AppIcon.icns", "AppIcon.icns",
    ]

    func resolve(workspaceRoot: String, faviconPath: String?) -> URL? {
        lock.withLock {
            let key = Key(root: workspaceRoot, path: faviconPath), now = Date()
            if let cached = entries[key], cached.expires > now { return cached.url }
            entries = entries.filter { $0.value.expires > now }
            let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let paths = faviconPath.map { [$0] + candidates } ?? candidates
            let found = paths.lazy.compactMap { path -> URL? in
                guard !path.isEmpty, !(path as NSString).isAbsolutePath else { return nil }
                let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(prefix), self.extensions.contains(url.pathExtension.lowercased()),
                      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      attrs[.type] as? FileAttributeType == .typeRegular,
                      let size = attrs[.size] as? UInt64, size <= 4 * 1024 * 1024 else { return nil }
                return url
            }.first
            entries[key] = Entry(url: found, expires: now.addingTimeInterval(found == nil ? 60 : 600))
            return found
        }
    }
}
