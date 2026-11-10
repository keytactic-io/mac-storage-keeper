import CoreServices
import Darwin
import Foundation

/// Metadata macOS already keeps about files: Spotlight dates and download provenance.
public enum FileMetadata {
    /// The app that downloaded a file, from the `com.apple.quarantine` attribute
    /// (format: "flags;timestamp;agent name;UUID"). Example: "Google Chrome".
    public static func downloadingApp(_ path: String) -> String? {
        let name = "com.apple.quarantine"
        let len = getxattr(path, name, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard getxattr(path, name, &buf, len, 0, 0) == len else { return nil }
        let parts = String(decoding: buf, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let agent = String(parts[2]).trimmingCharacters(in: .whitespaces)
        return agent.isEmpty ? nil : agent
    }

    private static func mdItem(_ path: String) -> MDItem? {
        MDItemCreate(kCFAllocatorDefault, path as CFString)
    }

    /// Source URLs recorded by the browser (Spotlight's "Where from").
    public static func whereFrom(_ path: String) -> [String] {
        guard let item = mdItem(path),
              let v = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return [] }
        return v
    }

    /// The host part of the download URL, e.g. "github.com".
    public static func sourceHost(_ path: String) -> String? {
        for s in whereFrom(path) {
            if let host = URL(string: s)?.host, !host.isEmpty { return host }
        }
        return nil
    }

    /// When the file was last opened, according to Spotlight.
    public static func lastUsed(_ path: String) -> Date? {
        guard let item = mdItem(path) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// When the file was added to its current folder (e.g. when the download finished).
    public static func dateAdded(_ path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        if let d = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate { return d }
        if let item = mdItem(path), let d = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date { return d }
        return nil
    }

    public static func modified(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// "via Google Chrome · github.com" for downloaded files, nil otherwise.
    public static func provenance(_ path: String) -> String? {
        let parts = [downloadingApp(path).map { "via \($0)" }, sourceHost(path)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
