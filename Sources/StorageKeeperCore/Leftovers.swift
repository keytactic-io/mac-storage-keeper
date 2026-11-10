import AppKit
import Foundation
import Security

/// Finds data folders left behind by apps that are no longer installed.
///
/// Apps keep data in ~/Library under their bundle ID (com.vendor.App) or name. A folder counts as
/// a leftover only when no installed or running app matches it AND nothing has written to it for a
/// while, which filters out helpers, CLI tools and background services that use these folders too.
public enum Leftovers {
    public static let recommendationID = "leftovers"

    public enum Confidence: String, Sendable {
        /// Bundle-ID folder with no matching app.
        case likely
        /// Plain-named folder with no app of that name.
        case possible
    }

    public struct Item: Sendable, Hashable {
        public var path: String
        public var bytes: Int64
        public var identifier: String
        public var location: String
        public var lastModified: Date
        public var confidence: Confidence
    }

    /// Locations scanned, with whether folder names there are bundle IDs.
    private static let locations: [(path: String, label: String)] = [
        ("~/Library/Application Support", "Application Support"),
        ("~/Library/Caches", "Caches"),
        ("~/Library/Containers", "Containers"),
        ("~/Library/Group Containers", "Group Containers"),
        ("~/Library/Logs", "Logs"),
        ("~/Library/HTTPStorages", "HTTP storage"),
        ("~/Library/WebKit", "WebKit data"),
        ("~/Library/Saved Application State", "Saved window state"),
        ("~/Library/Application Scripts", "Application Scripts"),
    ]

    /// Plain folder names that belong to macOS or shared frameworks, never to a removable app.
    private static let systemNames: Set<String> = [
        "addressbook", "callhistorydb", "callhistorytransactions", "clouddocs", "crashreporter", "knowledge",
        "dock", "diskimages", "syncservices", "applemediaservices", "animoji", "icdd", "networkserviceproxy",
        "accounts", "fileprovider", "icloud", "mobilesync", "familycircle", "sesstorage", "contextstoreagent",
        "homeenergyd", "locationaccessstoretests", "metadata", "quicklook", "spotlight", "siri", "assistant",
        "geoservices", "com.crashlytics", "sentrycrash", "google", "microsoft", "mozilla", "jetbrains",
        "videoconversionservice", "identityservices", "ubiquity", "storagemanagement", "tipsd", "transparency",
        "default.store", "cloudkit", "familysettings", "ffmpeg", "node", "nodejs", "npm", "python", "electron",
        // Generic names that don't identify an app (shared by updaters, frameworks, several apps).
        "caches", "cache", "logs", "log", "data", "temp", "tmp", "crashes", "crashpad", "updates", "updater",
        "plugins", "extensions", "shared", "common", "storage", "databases", "backups", "downloads",
    ]

    private struct InstalledIndex {
        var ids = Set<String>()
        var names = Set<String>()
        var teams = Set<String>()
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Bundle IDs, names and signing team IDs of installed apps (including helper apps inside bundles).
    private static func installedIndex() -> InstalledIndex {
        var idx = InstalledIndex()
        let fm = FileManager.default
        let roots = ["/Applications", Paths.expand("~/Applications"), "/System/Applications",
                     "/System/Applications/Utilities", "/Applications/Utilities", "/System/Library/CoreServices",
                     "/Library/Application Support"]

        func addApp(_ url: URL, depth: Int) {
            if let b = Bundle(url: url) {
                if let id = b.bundleIdentifier { idx.ids.insert(id.lowercased()) }
                for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                    if let n = b.object(forInfoDictionaryKey: key) as? String { idx.names.insert(normalize(n)) }
                }
            }
            idx.names.insert(normalize(url.deletingPathExtension().lastPathComponent))
            if depth == 0, let team = teamID(of: url) { idx.teams.insert(team) }
            // Helpers and login items have their own bundle IDs and data folders.
            guard depth < 2 else { return }
            for sub in ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/Frameworks", "Contents/Library/Helpers", "Contents/MacOS"] {
                let dir = url.appendingPathComponent(sub)
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".app") {
                    addApp(dir.appendingPathComponent(name), depth: depth + 1)
                }
            }
        }

        func walk(_ dir: String, depth: Int) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                let p = dir + "/" + name
                if name.hasSuffix(".app") {
                    addApp(URL(fileURLWithPath: p), depth: 0)
                } else if depth < 2, (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk(p, depth: depth + 1) // e.g. /Applications/Adobe Photoshop/…app
                }
            }
        }
        for r in roots { walk(r, depth: r == "/Library/Application Support" ? 1 : 0) }

        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { idx.ids.insert(id.lowercased()) }
            if let n = app.localizedName { idx.names.insert(normalize(n)) }
        }
        return idx
    }

    private static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }

    /// Most recent modification of a folder and its immediate children.
    private static func lastModified(_ path: String) -> Date {
        var latest = FileMetadata.modified(path) ?? .distantPast
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).prefix(500) {
            if let d = FileMetadata.modified(path + "/" + name), d > latest { latest = d }
        }
        return latest
    }

    private static func isInstalled(bundleID raw: String, index: InstalledIndex) -> Bool {
        var id = raw
        if id.lowercased().hasSuffix(".savedstate") { id = String(id.dropLast(".savedState".count)) }
        if id.lowercased().hasPrefix("group.") { id = String(id.dropFirst(6)) }
        // "TEAMID.com.vendor.shared" (Group Containers): installed if any app from that team is installed.
        let comps = id.split(separator: ".").map(String.init)
        if comps.count >= 2, comps[0].count == 10, comps[0] == comps[0].uppercased(),
           comps[0].allSatisfy({ $0.isLetter || $0.isNumber }) {
            if index.teams.contains(comps[0]) { return true }
            id = comps.dropFirst().joined(separator: ".")
        }
        id = id.lowercased()
        if index.ids.contains(id) { return true }
        // Helpers and extensions: com.vendor.App.Helper ↔ com.vendor.App
        for installed in index.ids where id.hasPrefix(installed + ".") || installed.hasPrefix(id + ".") { return true }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return true }
        return false
    }

    private static func isInstalled(name: String, index: InstalledIndex) -> Bool {
        let n = normalize(name)
        if n.count < 3 || index.names.contains(n) { return true }
        // "Google" ↔ "Google Chrome", "zoom.us" ↔ "zoom"
        return index.names.contains { $0.count >= 4 && (n.hasPrefix($0) || $0.hasPrefix(n)) }
    }

    /// - Parameters:
    ///   - bundleIDAge: bundle-ID folders must be untouched this long.
    ///   - nameAge: plain-named folders (less certain) must be untouched this long.
    public static func find(minBytes: Int64 = 5_000_000,
                            bundleIDAge: TimeInterval = 30 * 86400,
                            nameAge: TimeInterval = 90 * 86400) -> [Item] {
        let index = installedIndex()
        let now = Date()
        let fm = FileManager.default
        var out: [Item] = []

        for loc in locations {
            let dir = Paths.expand(loc.path)
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                let lower = name.lowercased()
                if lower.contains("com.apple.") || lower.hasPrefix("apple") || lower.contains("storagekeeper") { continue }
                let path = dir + "/" + name
                // Known tools (Playwright, Homebrew, editors…) are handled by their own rules.
                if let a = Attributor.shared.attribution(forRoot: path), a.category != .apps { continue }

                let confidence: Confidence
                let identifier: String
                let stem = lower.hasSuffix(".savedstate") ? String(name.dropLast(".savedState".count)) : name
                if looksLikeBundleID(stem) {
                    guard !isInstalled(bundleID: stem, index: index) else { continue }
                    confidence = .likely
                    identifier = stem
                } else {
                    // Plain names are only meaningful in Application Support, Caches and Logs.
                    guard ["Application Support", "Caches", "Logs"].contains(loc.label),
                          !systemNames.contains(lower), !systemNames.contains(normalize(name)),
                          !isInstalled(name: stem, index: index) else { continue }
                    confidence = .possible
                    identifier = stem
                }

                let modified = lastModified(path)
                let minAge = confidence == .likely ? bundleIDAge : nameAge
                guard now.timeIntervalSince(modified) >= minAge else { continue }
                let bytes = DiskScanner.size(of: path)
                guard bytes >= minBytes else { continue }
                out.append(Item(path: path, bytes: bytes, identifier: identifier, location: loc.label,
                                lastModified: modified, confidence: confidence))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Wraps the results as a cleanup recommendation (reviewed item by item, moved to the Trash).
    public static func recommendation(minBytes: Int64 = 5_000_000) -> Recommendation? {
        let found = find(minBytes: minBytes)
        guard !found.isEmpty else { return nil }
        let items = found.map { i -> RecItem in
            let what = i.confidence == .likely ? "No app “\(i.identifier)” installed" : "Possibly leftover: no app named “\(i.identifier)”"
            return RecItem(path: i.path, bytes: i.bytes,
                           detail: "\(what) · \(i.location) · untouched \(Fmt.relative(i.lastModified))")
        }
        return Recommendation(
            id: recommendationID, title: "Leftovers from removed apps",
            summary: "Data folders for apps that aren't installed and haven't been touched in a month or more. Check each one before removing.",
            category: .apps, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .review,
            caution: "Only remove folders for apps you deleted on purpose. If you reinstall one later, it starts fresh.")
    }
}
