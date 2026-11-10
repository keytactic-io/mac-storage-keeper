import Foundation

public enum Fmt {
    /// Human-readable byte count using decimal units, matching Finder.
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Short size for the menu bar: "850M", "1.2G", "12G".
    public static func compact(_ n: Int64) -> String {
        let v = Double(abs(n))
        if v >= 1e12 { return String(format: "%.1fT", v / 1e12) }
        if v >= 1e10 { return String(format: "%.0fG", v / 1e9) }
        if v >= 1e9 { return String(format: "%.1fG", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0fM", v / 1e6) }
        return String(format: "%.0fK", v / 1e3)
    }

    /// Signed byte delta, e.g. "+1.2 GB" / "−300 MB".
    public static func delta(_ n: Int64) -> String {
        if n == 0 { return "±0" }
        return (n > 0 ? "+" : "−") + bytes(abs(n))
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    public static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Replaces the home directory prefix with "~".
    public static func path(_ p: String) -> String {
        let home = Paths.home
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    /// Parses "90", "90d", "12h", "2w", "30m" into seconds. Bare numbers are days.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = t.last else { return nil }
        let unit: Double
        var num = t
        switch last {
        case "m": unit = 60; num.removeLast()
        case "h": unit = 3600; num.removeLast()
        case "d": unit = 86400; num.removeLast()
        case "w": unit = 7 * 86400; num.removeLast()
        default: unit = 86400
        }
        guard let v = Double(num), v >= 0 else { return nil }
        return v * unit
    }

    /// Parses "500MB", "1.5G", "200m", "1024" (bytes) into a byte count.
    public static func parseBytes(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = t.prefix { "0123456789.".contains($0) }
        guard let v = Double(digits) else { return nil }
        let suffix = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let mult: Double
        switch suffix {
        case "", "B": mult = 1
        case "K", "KB": mult = 1e3
        case "M", "MB": mult = 1e6
        case "G", "GB": mult = 1e9
        case "T", "TB": mult = 1e12
        default: return nil
        }
        return Int64(v * mult)
    }
}

public enum Paths {
    public static let home: String = FileManager.default.homeDirectoryForCurrentUser.path

    /// On APFS the user data lives on the Data volume, which is firmlinked into "/".
    public static let dataVolume = "/System/Volumes/Data"

    /// Default root for a whole-disk sweep. Scanning the Data volume directly avoids
    /// counting firmlinked folders twice and skips the read-only system volume.
    public static var defaultScanRoot: String {
        FileManager.default.fileExists(atPath: dataVolume) ? dataVolume : "/"
    }

    /// Maps "/System/Volumes/Data/Users/x" to "/Users/x" so paths match what users see.
    public static func normalize(_ p: String) -> String {
        if p == dataVolume { return "/" }
        if p.hasPrefix(dataVolume + "/") { return String(p.dropFirst(dataVolume.count)) }
        return p
    }

    public static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StorageKeeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var databaseURL: URL { supportDir.appendingPathComponent("storage.sqlite") }

    public static func parent(_ p: String) -> String {
        (p as NSString).deletingLastPathComponent
    }

    public static func name(_ p: String) -> String {
        (p as NSString).lastPathComponent
    }

    /// True when Full Disk Access appears to be granted to this process.
    /// Each probe is a location macOS only lets Full Disk Access apps read; any one succeeding is enough
    /// (some may not exist on a given Mac).
    public static var hasFullDiskAccess: Bool {
        let tcc = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        if let fh = FileHandle(forReadingAtPath: tcc) {
            try? fh.close()
            return true
        }
        for dir in ["/Library/Safari", "/Library/Mail", "/.Trash", "/Library/Containers/com.apple.Safari"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: home + dir)) != nil { return true }
        }
        return false
    }
}

public struct DiskInfo: Sendable {
    public var total: Int64
    /// Space available for important use (includes purgeable space), like Finder shows.
    public var available: Int64
    public var used: Int64 { total - available }
    public var fractionFree: Double { total > 0 ? Double(available) / Double(total) : 0 }

    public static func current(path: String = "/") -> DiskInfo? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) else { return nil }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let avail = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return DiskInfo(total: total, available: avail)
    }
}
