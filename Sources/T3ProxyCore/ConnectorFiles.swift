import Foundation
import Darwin

enum ConnectorFiles {
    static func tomlString(_ value: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]), as: UTF8.self).dropFirst().dropLast().description
    }
    /// Create private bytes before publishing the name; never leave a credential-bearing 0644 interval.
    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600, replacing: Bool = true) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".t3-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw ServiceConnectionError.storage }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temp) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ServiceConnectionError.storage }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ServiceConnectionError.storage }
        if replacing {
            guard rename(temp.path, url.path) == 0 else { throw ServiceConnectionError.storage }
        } else {
            guard link(temp.path, url.path) == 0 else { throw ServiceConnectionError.storage }
        }
    }
}
